# This file is part of https://github.com/astoff/comint-mime

def __COMINT_MIME_setup(types):
    ipython = False
    try:
        ipython = get_ipython()
        assert ipython
    except:
        import importlib.util
        if not importlib.util.find_spec("matplotlib"):
            print("`comint-mime' error: IPython or Matplotlib is required")
            return

    from base64 import encodebytes
    from functools import partial
    from json import dumps as to_json
    from pathlib import Path

    def encoding_workaround(data):
        if isinstance(data, str):
            from base64 import decodebytes
            return decodebytes(data.encode())
        return data

    SIZE_LIMIT = 4000

    def print_osc(type, encoder, data, meta):
        meta = meta or {}
        if encoder:
            data = encoder(data)
        header = to_json({**meta, "type": type})
        if len(data) > SIZE_LIMIT:
            from tempfile import mkstemp
            fdesc, fname = mkstemp()
            with open(fdesc, "wb") as f: f.write(data)
            payload = "tmp" + Path(fname).as_uri()
        else:
            payload = encodebytes(data).decode()
        print(f"\033]5151;{header}\n{payload}\033\\")

    if ipython:
        MIME_TYPES = {
            "image/png": encoding_workaround,
            "image/jpeg": encoding_workaround,
            "text/latex": str.encode,
            "text/html": str.encode,
            "application/json": lambda d: to_json(d).encode(),
        }

        if types == "all":
            types = MIME_TYPES
        else:
            types = types.split(";")

        ipython.enable_matplotlib("inline")
        ipython.display_formatter.active_types = list(MIME_TYPES.keys())
        for mime, encoder in MIME_TYPES.items():
            ipython.display_formatter.formatters[mime].enabled = mime in types
            ipython.mime_renderers[mime] = partial(print_osc, mime, encoder)

        if types:
            print("`comint-mime' enabled for",
                  ", ".join(t for t in types if t in MIME_TYPES.keys()))
        else:
            print("`comint-mime' disabled")
    else:
        from importlib.abc import Loader, MetaPathFinder
        from importlib.machinery import ModuleSpec
        from sys import meta_path
        from os import environ

        environ["MPLBACKEND"] = "module://emacscomintmime"

        from matplotlib import _api
        from matplotlib.backend_bases import FigureManagerBase
        from matplotlib.backends.backend_agg import FigureCanvasAgg

        class BackendModuleLoader(Loader):
            def create_module(self, spec):
                return None
            def exec_module(self, module):
                from io import BytesIO
                from base64 import encodebytes
                from json import dumps as to_json
                from pathlib import Path

                class FigureCanvasEmacsComintMime(FigureCanvasAgg):
                    manager_class = _api.classproperty(lambda cls: FigureManagerEmacsComintMime)

                    def __init__(self, *args, **kwargs):
                        super().__init__(*args, **kwargs)

                class FigureManagerEmacsComintMime(FigureManagerBase):

                    def __init__(self, canvas, num):
                        super().__init__(canvas, num)

                    def show(self):
                        self.canvas.figure.draw_without_rendering()
                        buf = BytesIO()
                        self.canvas.print_png(buf)
                        print_osc("image/png", encoding_workaround, buf.getvalue(), None)

                module.FigureCanvas = FigureCanvasEmacsComintMime
                module.FigureManager = FigureManagerEmacsComintMime

        class BackendModuleFinder(MetaPathFinder):
            def find_spec(self, fullname, path, target=None):
                if fullname == 'emacscomintmime':
                    return ModuleSpec(fullname, BackendModuleLoader())
                else:
                    return None

        meta_path.append(BackendModuleFinder())
        print("`comint-mime' enabled for Matplotlib")
