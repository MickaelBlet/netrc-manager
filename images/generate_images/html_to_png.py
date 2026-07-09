#!/usr/bin/env python3
# -*- coding:utf-8 -*-

import os
from concurrent.futures import ThreadPoolExecutor

from html2image import Html2Image
from PIL import Image

folder_path = os.path.dirname(os.path.realpath(__file__))
output_path = os.path.join(folder_path, "..")

SCALE = 3


def process(filename):
    filepath = os.path.join(folder_path, filename)
    name = os.path.splitext(os.path.basename(filepath))[0] + ".png"
    hti = Html2Image(
        output_path=output_path,
        size=(830 * SCALE, 1000 * SCALE),
        custom_flags=[
            "--default-background-color=00000000",
            "--hide-scrollbars",
            "--force-device-scale-factor={}".format(SCALE),
        ],
    )
    hti.screenshot(url="file://" + filepath, save_as=name)

    out = os.path.join(output_path, name)
    img = Image.open(out)
    img = img.crop(img.getbbox())
    img.save(out, optimize=True)


files = [f for f in os.listdir(folder_path) if f.endswith('.html')]

with ThreadPoolExecutor() as executor:
    list(executor.map(process, files))