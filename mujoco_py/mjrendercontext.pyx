from threading import Lock
from mujoco_py.generated import const
from contextlib import contextmanager

cdef class MjRenderContext(object):
    """
    Class that encapsulates rendering functionality for a
    MuJoCo simulation.
    """

    cdef mjModel *_model_ptr
    cdef mjData *_data_ptr

    cdef mjvScene _scn
    cdef mjvCamera _cam
    cdef mjvOption _vopt
    cdef mjvPerturb _pert
    cdef mjrContext _con

    # Public wrappers
    cdef readonly PyMjvScene scn
    cdef readonly PyMjvCamera cam
    cdef readonly PyMjvOption vopt
    cdef readonly PyMjvPerturb pert
    cdef readonly PyMjrContext con

    cdef readonly object opengl_context
    cdef readonly int _visible
    cdef readonly list _markers
    cdef readonly dict _overlay

    cdef readonly bint offscreen
    cdef public object sim

    def __cinit__(self):
        maxgeom = 1000
        print('mjv_makeScene(&scn, {});'.format(maxgeom))
        mjv_makeScene(&self._scn, maxgeom)
        print('mjv_defaultCamera(&cam);')
        mjv_defaultCamera(&self._cam)
        print('mjv_defaultOption(&opt);')
        mjv_defaultOption(&self._vopt)
        print('mjr_defaultContext(&con);')
        mjr_defaultContext(&self._con)

    def __init__(self, MjSim sim, bint offscreen=True, int device_id=-1):
        self.sim = sim
        self._setup_opengl_context(offscreen, device_id)
        self.offscreen = offscreen

        # Ensure the model data has been updated so that there
        # is something to render
        sim.forward()

        sim.add_render_context(self)

        self._model_ptr = sim.model.ptr
        self._data_ptr = sim.data.ptr
        self.scn = WrapMjvScene(&self._scn)
        self.cam = WrapMjvCamera(&self._cam)
        self.vopt = WrapMjvOption(&self._vopt)
        self.con = WrapMjrContext(&self._con)
        self._pert.active = 0
        self._pert.select = 0
        self.pert = WrapMjvPerturb(&self._pert)

        self._markers = []
        self._overlay = {}

        self._init_camera(sim)
        self._set_mujoco_buffers()

    def _set_camera(self, id, type):
        print('cam.fixedcamid = {};'.format(id))
        self.cam.fixedcamid = id
        print('cam.type = {};'.format(type))
        self.cam.type = type
        print('mjv_updateCamera(m, d, &cam, &scn);')
        mjv_updateCamera(self._model_ptr, self._data_ptr, &self._cam, &self._scn)

    def _set_free_camera(self):
        self._set_camera(-1, const.CAMERA_FREE)

    @contextmanager
    def _camera(self, id):
        if id is None:
            id = -1
        assert type(id) is int
        if id != -1:
            self._set_camera(id, const.CAMERA_FIXED)

        yield
        self._set_free_camera()


    def update_sim(self, MjSim new_sim):
        if new_sim == self.sim:
            return
        self._model_ptr = new_sim.model.ptr
        self._data_ptr = new_sim.data.ptr
        self._set_mujoco_buffers()
        for render_context in self.sim.render_contexts:
            new_sim.add_render_context(render_context)
        self.sim = new_sim

    def _set_mujoco_buffers(self):
        self.pre = "//offscreen\n" if self.offscreen else "//window\n"
        print(self.pre + 'mjr_makeContext(model, &con, mjFONTSCALE_150);')
        mjr_makeContext(self._model_ptr, &self._con, mjFONTSCALE_150)
        if self.offscreen:
            print(self.pre + 'mjr_setBuffer(mjFB_OFFSCREEN, &con);')
            mjr_setBuffer(mjFB_OFFSCREEN, &self._con);
            if self._con.currentBuffer != mjFB_OFFSCREEN:
                raise RuntimeError('Offscreen rendering not supported')
        else:
            print(self.pre + 'mjr_setBuffer(mjFB_WINDOW, &self.con);')
            mjr_setBuffer(mjFB_WINDOW, &self._con);
            if self._con.currentBuffer != mjFB_WINDOW:
                raise RuntimeError('Window rendering not supported')
        self.con = WrapMjrContext(&self._con)

    def _setup_opengl_context(self, offscreen, device_id):
        if not offscreen or sys.platform == 'darwin':
            self.opengl_context = GlfwContext(offscreen=offscreen)
        else:
            if device_id < 0:
                if "GPUS" in os.environ:
                    device_id = int(os.environ["GPUS"].split(',')[0])
                else:
                    device_id = int(os.getenv('CUDA_VISIBLE_DEVICES', '0').split(',')[0])
            self.opengl_context = OffscreenOpenGLContext(device_id)

    def _init_camera(self, sim):
        # Make the free camera look at the scene
        self._set_free_camera()
        for i in range(3):
            self.cam.lookat[i] = sim.model.stat.center[i]
        self.cam.distance = sim.model.stat.extent

    def update_offscreen_size(self, width, height):
        if width != self._con.offWidth or height != self._con.offHeight:
            self._model_ptr.vis.global_.offwidth = width
            self._model_ptr.vis.global_.offheight = height
            print(self.pre + 'mjr_freeContext(&self.con);')
            mjr_freeContext(&self._con)
            self._set_mujoco_buffers()

    def render(self, dimensions=None, camera_id=None, visible=True):
        if dimensions is None:
            dimensions = self.opengl_context.get_buffer_size()
        height, width = dimensions
        print('mjrRect render_rect;')
        cdef mjrRect rect
        rect.left = 0
        rect.bottom = 0
        rect.width = width
        print(self.pre + 'render_rect.width = {};'.format(width))
        rect.height = height
        print(self.pre + 'render_rect.height = {};'.format(height))

        # Sometimes buffers are too small.
        if width > self._con.offWidth or height > self._con.offHeight:
            new_width = max(width, self._model_ptr.vis.global_.offwidth)
            new_height = max(height, self._model_ptr.vis.global_.offheight)
            self.update_offscreen_size(new_width, new_height)

        with self._camera(camera_id):
            if visible:
                self.opengl_context.set_buffer_size(width, height)

            print(self.pre + 'mjv_updateScene(model, d, &opt, &pert, &cam, mjCAT_ALL, &scn);')
            mjv_updateScene(self._model_ptr, self._data_ptr, &self._vopt,
                            &self._pert, &self._cam, mjCAT_ALL, &self._scn)

            for marker_params in self._markers:
                self._add_marker_to_scene(marker_params)

            print(self.pre + 'mjr_render(rect, &scn, &con);')
            mjr_render(rect, &self._scn, &self._con)
            for gridpos, (text1, text2) in self._overlay.items():
                mjr_overlay(const.FONTSCALE_150, gridpos, rect, text1.encode(), text2.encode(), &self._con)

    def read_pixels(self, width, height, depth=True):
        print(self.pre + 'mjrRect read_pixels_rect;')
        cdef mjrRect rect
        rect.left = 0
        rect.bottom = 0
        print(self.pre + 'read_pixels_rect.width = {};'.format(width))
        rect.width = width
        print(self.pre + 'read_pixels_rect.height = {};'.format(height))
        rect.height = height

        rgb_arr = np.zeros(3 * rect.width * rect.height, dtype=np.uint8)
        depth_arr = np.zeros(rect.width * rect.height, dtype=np.float32)
        cdef unsigned char[::view.contiguous] rgb_view = rgb_arr
        cdef float[::view.contiguous] depth_view = depth_arr
        print(self.pre + 'mjr_readPixels(rgb, NULL, rect, &con);')
        mjr_readPixels(&rgb_view[0], &depth_view[0], rect, &self._con)
        rgb_img = rgb_arr.reshape(rect.height, rect.width, 3)
        if depth:
            depth_img = depth_arr.reshape(rect.height, rect.width)
            return (rgb_img, depth_img)
        else:
            return rgb_img

    def upload_texture(self, int tex_id):
        """ Uploads given texture to the GPU. """
        self.opengl_context.make_context_current()
        print(self.pre + 'mjr_uploadTexture(m, &con, tex_id);')
        mjr_uploadTexture(self._model_ptr, &self._con, tex_id)

    def draw_pixels(self, np.ndarray[np.uint8_t, ndim=3] image, int left, int bottom):
        """Draw an image into the OpenGL buffer."""
        cdef unsigned char[::view.contiguous] image_view = image.ravel()
        cdef mjrRect viewport
        viewport.left = left
        viewport.bottom = bottom
        viewport.width = image.shape[1]
        viewport.height = image.shape[0]
        print(self.pre + 'mjr_drawPixels(&image_view[0], NULL, viewport, &self._con);')
        mjr_drawPixels(&image_view[0], NULL, viewport, &self._con)

    def move_camera(self, int action, double reldx, double reldy):
        """ Moves the camera based on mouse movements. Action is one of mjMOUSE_*. """
        print(self.pre + 'mjv_moveCamera(m, action, reldx, reldy, &scn, &cam);')
        mjv_moveCamera(self._model_ptr, action, reldx, reldy, &self._scn, &self._cam)

    def add_overlay(self, int gridpos, str text1, str text2):
        """ Overlays text on the scene. """
        if gridpos not in self._overlay:
            self._overlay[gridpos] = ["", ""]
        self._overlay[gridpos][0] += text1 + "\n"
        self._overlay[gridpos][1] += text2 + "\n"

    def add_marker(self, **marker_params):
        self._markers.append(marker_params)

    def _add_marker_to_scene(self, marker_params):
        """ Adds marker to scene, and returns the corresponding object. """
        if self._scn.ngeom >= self._scn.maxgeom:
            raise RuntimeError('Ran out of geoms. maxgeom: %d' % self._scn.maxgeom)

        cdef mjvGeom *g = self._scn.geoms + self._scn.ngeom

        # default values.
        g.dataid = -1
        g.objtype = const.OBJ_UNKNOWN
        g.objid = -1
        g.category = const.CAT_DECOR
        g.texid = -1
        g.texuniform = 0
        g.texrepeat[0] = 1
        g.texrepeat[1] = 1
        g.emission = 0
        g.specular = 0.5
        g.shininess = 0.5
        g.reflectance = 0
        g.type = const.GEOM_BOX
        g.size[:] = np.ones(3) * 0.1
        g.mat[:] = np.eye(3).flatten()
        g.rgba[:] = np.ones(4)
        wrapped = WrapMjvGeom(g)

        for key, value in marker_params.items():
            if isinstance(value, (int, float)):
                setattr(wrapped, key, value)
            elif isinstance(value, (tuple, list, np.ndarray)):
                attr = getattr(wrapped, key)
                attr[:] = np.asarray(value).reshape(attr.shape)
            elif isinstance(value, str):
                assert key == "label", "Only label is a string in mjvGeom."
                if value == None:
                    g.label[0] = 0
                else:
                    strncpy(g.label, value.encode(), 100)
            elif hasattr(wrapped, key):
                raise ValueError("mjvGeom has attr {} but type {} is invalid".format(key, type(value)))
            else:
                raise ValueError("mjvGeom doesn't have field %s" % key)

        self._scn.ngeom += 1


    def __dealloc__(self):
        print(self.pre + 'mjr_freeContext(con);')
        mjr_freeContext(&self._con)
        print(self.pre + 'mjv_freeScene(scn);')
        mjv_freeScene(&self._scn)

    @property
    def window(self):
        return self.opengl_context.window


class MjRenderContextOffscreen(MjRenderContext):

    def __cinit__(self, MjSim sim, int device_id):
        self.pre = '//offscreen\n'
        super().__init__(sim, offscreen=True, device_id=device_id)

class MjRenderContextWindow(MjRenderContext):

    def __init__(self, MjSim sim):
        self.pre = '//window\n'
        super().__init__(sim, offscreen=False)

        assert isinstance(self.opengl_context, GlfwContext), (
            "Only GlfwContext supported for windowed rendering")

    @property
    def window(self):
        return self.opengl_context.window

    def render(self, dimensions=None, camera_id=None):
        if self.window is None or glfw.window_should_close(self.window):
            return

        super().render(dimensions, camera_id, visible=True)
        print(self.pre + 'glfwSwapBuffers(window);')
        glfw.swap_buffers(self.window)
