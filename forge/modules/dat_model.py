"""
DAT upscaler scanner — mirrors UpscalerESRGAN but scoped to models/DAT/.

Forge's modelloader already loads any model architecture Spandrel
recognises (ESRGAN, DAT, ATD, DRCT, SwinIR, ...) from a `.pth` or
`.safetensors` file. The gap is purely the scanner: `UpscalerESRGAN`
only walks the ESRGAN directory, so DAT files sitting in their own
`models/DAT/` folder never make it into `shared.sd_upscalers`.

This class plugs that gap. Loading/inference are inherited unchanged
from `UpscalerESRGAN` — only the brand and scan path differ.
"""
import re

from modules import modelloader
from modules.esrgan_model import UpscalerESRGAN
from modules.upscaler import Upscaler, UpscalerData


class UpscalerDAT(UpscalerESRGAN):
    def __init__(self, dirname: str):
        self.user_path = dirname
        self.model_path = dirname

        # Skip ESRGAN's `__init__` — it sets the ESRGAN name and installs
        # a placeholder pointing at the upstream ESRGAN.pth URL when the
        # scan turns up empty. We want neither.
        Upscaler.__init__(self, True)

        self.name = "DAT"
        self.model_name = "DAT"
        self.model_url = None
        self.scalers = []

        for file in self.find_models(ext_filter=[".pt", ".pth", ".safetensors"]):
            name = modelloader.friendly_name(file)
            scale_match = re.search(r"(\d)[xX]|[xX](\d)", name)
            scale = int(scale_match.group(1) or scale_match.group(2)) if scale_match else 4
            self.scalers.append(UpscalerData(name, file, self, scale))
