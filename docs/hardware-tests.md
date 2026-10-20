# Physical hardware tests

These are initial targets, not a tested compatibility list. Model names are
user-reported; exact variants and firmware remain to be recorded.

| Target | Candidate route | Current evidence | Next physical check |
| --- | --- | --- | --- |
| Hollyland Mars 300 Pro | Direct Wi-Fi investigation; receiver HDMI capture fallback | Vendor app monitoring documented; our input unverified | Confirm revision/firmware, vendor-app baseline, and usable Mac input |
| Accsoon CineView Master 4K | Direct integration investigation; SEE RTMP/SRT bridge or receiver capture | MacBook monitoring and app push documented; our input unverified | Confirm SEE baseline and local destination/SDK feasibility |
| Original Hollyland Mars 300 | Receiver HDMI through compatible capture device | HDMI topology documented; no direct network input established | Confirm physical receiver output and captured picture/audio |

For every pass or failure, record model, variant, firmware, Mac architecture,
connection route, input format, audio, measured delay, source-loss recovery,
and interaction with other receivers or vendor apps. Record simultaneous
source operation separately.

## Source-content coverage

For each viable connection route, test both a computer display and camera video. A DigiTech screen such as Capture One is a primary workflow, not a special camera mode. Record computer output resolution and refresh rate, source aspect ratio, small-text legibility, fine image detail, optional audio, and behavior after display sleep or an output-format change. These physical checks are not yet run.

Direct capture of the receiving Mac's own screen is separate from receiving a computer display through a transmitter or capture input. It is not implemented in this checkpoint.
