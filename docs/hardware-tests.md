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
camera operation separately.
