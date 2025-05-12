#!/bin/sh

vspipe --arg input=input.mov script.vpy - | ffmpeg -i - encoded.mkv
# vspipe --arg input=input.mov script.vpy output.raw