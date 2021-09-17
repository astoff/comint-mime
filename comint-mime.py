# This file is part of https://github.com/astoff/comint-mime

def __COMINT_MIME_setup(types):
    try:
        import IPython, matplotlib
        ipython = IPython.get_ipython()
        matplotlib.use('module://ipykernel.pylab.backend_inline')
    except:
        print("`comint-mime': error setting up")
        return

    from base64 import encodebytes
    from json import dumps as to_json
    from functools import partial

    OSC = '\033]5151;'
    ST = '\033\\'

    MIME_TYPES = {
        "image/png": None,
        "image/jpeg": None,
        "text/latex": str.encode,
        "text/html": str.encode,
        "application/json": lambda d: to_json(d).encode(),
    }
    
    if types == "all":
        types = MIME_TYPES
    else:
        types = types.split(";")

    def print_osc(type, encoder, data, meta):
        meta = meta or {}
        if encoder:
            data = encoder(data)
        header = to_json({**meta, "type": type})
        payload = encodebytes(data).decode()
        print(f'{OSC}{header}\n{payload}{ST}')

    ipython.display_formatter.active_types = list(MIME_TYPES.keys())
    for mime, encoder in MIME_TYPES.items():
        ipython.display_formatter.formatters[mime].enabled = mime in types
        ipython.mime_renderers[mime] = partial(print_osc, mime, encoder)

    if types:
        print("`comint-mime' enabled for",
              ", ".join(t for t in types if t in MIME_TYPES.keys()))
    else:
        print("`comint-mime' disabled")
