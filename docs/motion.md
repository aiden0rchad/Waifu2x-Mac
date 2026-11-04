# GIFs and video

The app extracts frames, processes them, and assembles the output. Video runs can also encode and mux audio. Start with a few seconds of footage or a small GIF so you can check the result and estimate how long a larger run might take.

## Animated GIF

1. Add a GIF and pick a 2× upscale. Real-CUGAN is a starting point for illustrated motion.
2. Run it with **Smoother motion** off. Compare timing and transparency against the source.
3. For a second run, turn on **Smoother motion** and start with **2× frames**. Watch for warped outlines around fast cuts or occlusions.
4. Try **Smaller GIFs** for a size pass if Gifsicle is installed. Compare appearance and file size with the first export.

A GIF can get much larger when both frame size and frame count increase. For a long animation, keep a separate copy of your original while you test output settings.

## Video

1. Start with a short MP4 or MOV. Use **MetalFX** for a quick check or choose the engine that fits your footage.
2. In **Advanced… → Video**, try **H.264** and a middle CRF for the first export. Lower CRF usually increases quality and file size. HEVC is an option if your playback device supports it.
3. Choose a writable output folder on a volume with room for temporary frames. Run the job and play the result through a few edits and dialogue.
4. Check dimensions, frame rate, and audio. You can read stream details with the same FFmpeg install the app uses.

```sh
ffprobe -v error -show_entries stream=codec_type,codec_name,width,height,avg_frame_rate \
  -of json "/path/to/output.mp4"
```

## Smoother motion and cost

RIFE predicts frames between existing ones. A 2× frame multiplier aims for twice as many frames, such as 24 fps to about 48 fps when duration is preserved. The result depends on the input and video settings. It can struggle with edits, subtitles, and foreground objects moving across textured backgrounds.

Doubling width and height makes each frame four times larger. Combining that with twice the frames can produce roughly eight times as many pixels to process. Runtime, temporary disk use, and encoded file size also depend on the engine, source, and encoder.

Use [Advanced settings](advanced.md) for encoding choices and [Troubleshooting](troubleshooting.md) when extraction or encoding fails.
