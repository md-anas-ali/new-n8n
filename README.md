# n8n docker setup for the "cinematic motion v2 master control" workflow

## What's in this folder
- `Dockerfile` - n8n's official Alpine image (pinned to the 1.x line -
  see below) + ffmpeg, python3, edge-tts, curl, fonts
- `docker-compose.yml` - runs it with hard memory caps
- `.env.example` - every env var the workflow reads (copy to `.env` and fill in)

## Why the base image is pinned to `n8nio/n8n:1.123.52`, not `:latest`
`:latest` now tracks n8n's newer 2.x line, which runs Code-node execution in
a separate task-runner process by default - that's a second Node.js
process's worth of baseline RAM on top of the main one, and its images run
~334-364MB compressed vs ~297MB for the 1.x line. n8n is still actively
patching 1.x (last image push was hours old at the time of writing), so
this isn't an abandoned/insecure version - it's the older, lighter, still-
maintained line. Every node type/version this workflow uses was already
supported well before 1.123, so nothing here needs 2.x. No other files
changed for this - same Dockerfile/compose/README, just the one `FROM` line.

## Quick start
```bash
cp .env.example .env
nano .env                     # add your API keys
docker compose up -d --build
```
Open `http://<your-server-ip>:5678`, finish the first-run owner setup, then
**Import from File** and pick the workflow JSON. Add your Google Sheets /
YouTube / Gemini credentials in n8n's own credential store (these are NOT env
vars - only the keys listed in `.env.example` are).

## Being honest about the strict 400MB cap
Everything that can be tightened from *inside* the workflow/container has
now been tightened:
- Render resolution dropped from `720x1280` to `640x1136` **everywhere**
  (image generation, every "Make Clip" ffmpeg pass including the
  retry-light fallback, the placeholder image) - about 21% fewer pixels
  per frame flowing through the heaviest step, "Concat + BGM + Subtitle"
  (color grade + glow + noise + vignette + subtitle burn, all one filter
  graph). Subtitle font size/margins were scaled down to match so captions
  stay proportioned.
- `NODE_OPTIONS=--max-old-space-size=170` (was 200) - caps n8n's own JS
  heap tighter. This only affects n8n's Node.js process; ffmpeg runs as a
  separate OS process and isn't limited by this flag.
- `UV_THREADPOOL_SIZE=2` and `N8N_PUBLIC_API_DISABLED=true` added - small,
  real savings (fewer libuv worker threads, no public-API surface loaded).
- `docker-compose.yml` now enforces `mem_limit: 400m` as the hard ceiling
  (was 460m), with `mem_reservation: 300m`.

Where I still have to be straight with you: **n8n itself (Node.js + the
app) idles around 150-250MB** before any workflow even runs. That's not
something a workflow JSON or an env var can shrink away - it's the
baseline cost of running Node.js + Express + n8n's editor UI. At a hard
400MB cap with **no swap**, a brief spike during the heaviest ffmpeg pass
crossing the ceiling is a real risk, not a hypothetical one, even with all
the trims above.

**The fix that makes 400MB survivable: swap.** You said slow is fine, RAM
running out is not - swap is exactly that trade, and at this cap it's
mandatory, not optional. Add it once on the host (outside Docker):
```bash
sudo fallocate -l 512M /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab   # survive reboot
```
`docker-compose.yml` already sets `memswap_limit: 900m` (400m RAM + 500m
swap) to match. With this in place, a spike turns into "slower for a few
seconds," not a crash. Without it, `mem_limit: 400m` WILL let Docker
OOM-kill the container the instant it's crossed - there's no cushion left
to trim any further from inside the app.

## If it still gets OOM-killed
1. Check actual usage: `docker stats n8n-viral-shorts`
2. Confirm swap is actually on: `free -h` should show a non-zero Swap row.
   This is the single most common cause of an OOM-kill at this cap.
3. Lower `NODE_OPTIONS=--max-old-space-size` further (e.g. to 140) - trades
   n8n UI/editor responsiveness for headroom; doesn't touch ffmpeg.
4. If you can tolerate visibly softer video, lower `Make Clip`'s resolution
   further than `640x1136` (e.g. `480x854`) and drop the final encode's
   `-r 30` to `-r 24`.
5. If none of that is enough, 400MB genuinely isn't enough to run n8n's
   full editor UI + this pipeline reliably - the next real lever is a host
   with more RAM, not a smaller config.

## Notes
- No Postgres/Redis container - stays on n8n's default SQLite, which is the
  right call for a box this small (a Postgres container alone typically
  needs 100MB+).
- `/tmp` is left as a normal disk-backed layer, not `tmpfs`, on purpose - a
  `tmpfs` mount would count the scene images/clips against your RAM budget
  too.
