import vapoursynth as vs
from vapoursynth import core

import havsfunc as haf
import mvsfunc as mvf

from pathlib import Path

def main():
    # Check variables
    if not input:
        # Exit if input is empty
        raise ValueError("Input is empty")

    # Get the video path
    video_path = Path(str(input))

    # Import video
    extension = video_path.suffix
    if extension == ".avi":
        video = core.avisource.AVISource(video_path)
        video = core.resize.Bicubic(clip=video, format=vs.YUV420P8, matrix_s="709")
    else:
        video = core.lsmas.LWLibavSource(source=video_path)

    # Resize
    if int(resize) == 1:
        out_width = out_width if out_width else 1280
        out_height = out_height if out_height else 720

        # Encode gamma
        video = core.resize.Bicubic(video, transfer_s='linear', transfer_in_s='709')
        video = core.std.Limiter(video, 0, 1)
        video = core.std.Pow(video, 2.2)  # Encode gamma as 2.2

        # Perform scaling
        video = core.resize.Bicubic(video, width=out_width, height=out_height)

        # Apply gamma decoding
        video = core.std.Pow(video, (1/2.2))  # Decode previously set gamma 2.2
        video = core.std.Limiter(video, 0, 1)
        video = core.resize.Bicubic(video, transfer_s='709', transfer_in_s='linear')

    # Check if the video is interlaced
    interlaced = core.std.BlankClip(clip=video, width=video.width, height=1, format=vs.GRAY8, length=1)
    interlaced = core.std.CopyFrameProps(interlaced, video)
    interlaced = core.std.SetFrameProp(interlaced, prop='_FieldBased', intval=2)
    interlaced = core.std.SetFrameProp(interlaced, prop='_Field', intval=0)
    interlaced = core.resize.Point(interlaced, format=video.format.id)

    # Deinterlace if the video is interlaced
    if interlaced.props.get('_FieldBased', 0) > 0:
        # Video is interlaced
        video = haf.QTGMC(video, EdiMode="NNEDI3")

    # Set output
    video.set_output()

if __name__ == '__vapoursynth__':
    main()