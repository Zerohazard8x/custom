import vapoursynth as vs
from vapoursynth import core
from vsrife import RIFE

# append to sys path
import sys,os
sys.path.append(os.getcwd())

# import blur_plugins.deduplicate as deduplicate
import blur_plugins.blending as blending
import blur_plugins.weighting as weighting
import blur_plugins.interpolate as interpolate

from pathlib import Path

def main():
    # Check variables
    if not input:
        # Exit if input is empty
        raise ValueError("Input is empty")

    out_fps = out_fps if out_fps else 30 # If out_fps is empty, set to 30
    interp_method = interp_method.lower() if interp_method else "rife" # If interp_method is empty, set to "rife"
    resize = resize if resize else 0 # no resize by default

    # Get video path
    video_path = Path(str(input))

    # Import video based on extension
    extension = video_path.suffix
    if extension == ".avi":
        video = core.avisource.AVISource(video_path)
        video = core.resize.Bicubic(clip=video, format=vs.YUV420P8)
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

    # Deduplicate (uncomment if needed)
    # video = deduplicate.fill_drops_old(video)

    if interp_method == "rife":
        video = core.resize.Bicubic(video, format=vs.RGBS)
        while video.fps < (out_fps) * 16:
            video = RIFE(video)  # Interpolate to 16x output
        video = core.resize.Bicubic(video, format=vs.YUV420P8)
    else:
        video = interpolate.interpolate_svp(video, new_fps=(out_fps)*16, gpu=True) # interpolate to 16x output

    # Frame blending
    blended_frames = max(int(video.fps / out_fps), 1)
    if blended_frames % 2 == 0:
        blended_frames += 1
    weights = weighting.equal(blended_frames)
    video = blending.average(video, weights)

    # Set output
    video.set_output()

if __name__ == '__vapoursynth__':
    main()