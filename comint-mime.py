# This file is part of https://github.com/astoff/comint-mime  -*- tab-width: 4; -*-
def __COMINT_MIME_setup(types, size_limit=4000):
	import base64, functools, json, pathlib

	def encoding_workaround(data):
		return base64.decodebytes(data.encode()) if isinstance(data, str) else data

	def print_osc(type, encoder, data, meta=None):
		if encoder: data = encoder(data)
		header = json.dumps({**(meta or {}), "type": type})
		if len(data) > size_limit:
			from tempfile import mkstemp
			fdesc, fname = mkstemp()
			with open(fdesc, "wb") as f: f.write(data)
			payload = "tmp" + pathlib.Path(fname).as_uri()
		else:
			payload = base64.encodebytes(data).decode()
		print(f"\033]5151;{header}\n{payload}\033\\")

	try:
		ipython = get_ipython(); assert ipython
		MIME_TYPES = {
			"image/png": encoding_workaround,
			"image/jpeg": encoding_workaround,
			"text/latex": str.encode,
			"text/html": str.encode,
			"application/json": lambda d: json.dumps(d).encode(),
		}
		enabled = MIME_TYPES if types == "all" else types.split(";")
		ipython.enable_matplotlib("inline")
		ipython.display_formatter.active_types = list(MIME_TYPES.keys())
		for mime, encoder in MIME_TYPES.items():
			ipython.display_formatter.formatters[mime].enabled = mime in enabled
			ipython.mime_renderers[mime] = functools.partial(print_osc, mime, encoder)
		print("`comint-mime' enabled for", list(t for t in enabled if t in MIME_TYPES))
	except:
		try:
			import importlib, io, sys, matplotlib
			from matplotlib.backend_bases import FigureManagerBase
			from matplotlib.backends.backend_agg import FigureCanvasAgg
		except:
			print("`comint-mime' error: IPython or Matplotlib required")
			return

		class FC(FigureCanvasAgg):
			manager_class = matplotlib._api.classproperty(lambda cls: FM)

		class FM(FigureManagerBase):
			def show(self):
				self.canvas.figure.draw_without_rendering()
				buf = io.BytesIO()
				self.canvas.print_png(buf)
				print_osc("image/png", None, buf.getvalue())

		mod = importlib.util.module_from_spec(importlib.machinery.ModuleSpec("__comint_mime", None))
		mod.FigureCanvas = FC
		mod.FigureManager = FM
		sys.modules[mod.__name__] = mod
		matplotlib.use("module://" + mod.__name__)
		print("`comint-mime' enabled, using Matplotlib backend")
