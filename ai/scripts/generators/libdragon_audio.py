"""Deep libdragon audio: mixer, wav64, xm64, advanced audio patterns."""


def gen_libdragon_audio() -> list[dict]:
    pairs = []

    def add(instruction, output):
        pairs.append({"instruction": instruction, "output": output,
                       "source": "generated", "category": "libdragon_audio"})

    # === Mixer ===
    add("How does the libdragon audio mixer work?",
        "The mixer is a software audio mixing engine that runs on the RSP. It mixes "
        "multiple channels of audio into a single stereo output.\n\n"
        "Setup in Pak:\n"
        "```pak\nuse n64.audio\n\nextern \"C\" {\n"
        "    fn mixer_init(num_channels: i32)\n"
        "    fn mixer_close()\n"
        "    fn mixer_poll(out: *i16, nsamples: i32)\n"
        "    fn mixer_set_vol(vol: f32)\n"
        "    fn mixer_ch_set_vol(ch: i32, lvol: f32, rvol: f32)\n"
        "    fn mixer_ch_set_vol_pan(ch: i32, vol: f32, pan: f32)\n"
        "    fn mixer_ch_play(ch: i32, wave: *waveform_t)\n"
        "    fn mixer_ch_stop(ch: i32)\n"
        "    fn mixer_ch_playing(ch: i32) -> bool\n"
        "    fn mixer_ch_set_freq(ch: i32, freq: f32)\n}\n\n"
        "entry {\n    audio.init(44100, 4)\n    mixer_init(8)  -- 8 channels\n\n"
        "    loop {\n"
        "        -- mixer_poll fills audio buffers automatically\n"
        "        -- when using wav64/xm64, mixer handles the output\n"
        "        let buf: *i16 = audio.get_buffer()\n"
        "        if buf != none {\n"
        "            mixer_poll(buf, 735)  -- 44100/60 = 735 samples\n"
        "        }\n    }\n}\n```\n\n"
        "Channel count doesn't affect performance until channels are actually playing.")

    add("How do I set channel volume and panning in Pak?",
        "```pak\nextern \"C\" {\n"
        "    fn mixer_ch_set_vol(ch: i32, lvol: f32, rvol: f32)\n"
        "    fn mixer_ch_set_vol_pan(ch: i32, vol: f32, pan: f32)\n"
        "    fn mixer_set_vol(vol: f32)\n}\n\n"
        "-- per-channel volume (left, right independently)\n"
        "mixer_ch_set_vol(0, 0.8, 0.8)  -- 80% both channels\n"
        "mixer_ch_set_vol(1, 1.0, 0.0)  -- left only\n\n"
        "-- or use pan (0.0 = left, 0.5 = center, 1.0 = right)\n"
        "mixer_ch_set_vol_pan(0, 1.0, 0.5)  -- full volume, centered\n"
        "mixer_ch_set_vol_pan(1, 0.5, 0.0)  -- half volume, full left\n\n"
        "-- master volume affects all channels\n"
        "mixer_set_vol(0.7)  -- 70% master\n```")

    # === WAV64 ===
    add("How do I play sound effects on N64 in Pak?",
        "Use wav64 for sound effects. WAV files are converted to .wav64 format "
        "by the build system:\n\n"
        "```pak\nextern \"C\" {\n"
        "    fn wav64_open(wav: *wav64_t, path: *c_char)\n"
        "    fn wav64_play(wav: *wav64_t, channel: i32)\n"
        "    fn wav64_set_loop(wav: *wav64_t, do_loop: bool)\n"
        "    fn wav64_close(wav: *wav64_t)\n"
        "    fn mixer_init(num_channels: i32)\n"
        "    fn mixer_poll(out: *i16, nsamples: i32)\n}\n\n"
        "static sfx_jump: wav64_t = undefined\n"
        "static sfx_shoot: wav64_t = undefined\n\n"
        "fn init_audio() {\n"
        "    audio.init(44100, 4)\n    mixer_init(8)\n"
        "    wav64_open(&sfx_jump, \"sfx/jump.wav64\")\n"
        "    wav64_open(&sfx_shoot, \"sfx/shoot.wav64\")\n}\n\n"
        "fn play_jump() {\n    wav64_play(&sfx_jump, 0)\n}\n"
        "fn play_shoot() {\n    wav64_play(&sfx_shoot, 1)\n}\n\n"
        "-- in game loop:\nlet buf: *i16 = audio.get_buffer()\n"
        "if buf != none { mixer_poll(buf, 735) }\n```")

    add("How do I play looping ambient sounds in Pak?",
        "```pak\nextern \"C\" {\n"
        "    fn wav64_open(wav: *wav64_t, path: *c_char)\n"
        "    fn wav64_play(wav: *wav64_t, channel: i32)\n"
        "    fn wav64_set_loop(wav: *wav64_t, do_loop: bool)\n"
        "    fn mixer_ch_set_vol_pan(ch: i32, vol: f32, pan: f32)\n}\n\n"
        "static ambient_wind: wav64_t = undefined\n\n"
        "fn start_ambient() {\n"
        "    wav64_open(&ambient_wind, \"sfx/wind.wav64\")\n"
        "    wav64_set_loop(&ambient_wind, true)  -- loop forever\n"
        "    wav64_play(&ambient_wind, 4)  -- use channel 4\n"
        "    mixer_ch_set_vol_pan(4, 0.3, 0.5)  -- quiet, centered\n}\n```")

    # === XM64 (tracker music) ===
    add("How do I play music on N64 in Pak?",
        "Use xm64 for tracker music. XM/MOD files are converted to .xm64 format:\n\n"
        "```pak\nextern \"C\" {\n"
        "    fn xm64player_open(player: *xm64player_t, path: *c_char)\n"
        "    fn xm64player_play(player: *xm64player_t, first_channel: i32)\n"
        "    fn xm64player_stop(player: *xm64player_t)\n"
        "    fn xm64player_set_vol(player: *xm64player_t, vol: f32)\n"
        "    fn xm64player_set_loop(player: *xm64player_t, do_loop: bool)\n"
        "    fn xm64player_num_channels(player: *xm64player_t) -> i32\n"
        "    fn xm64player_close(player: *xm64player_t)\n"
        "    fn mixer_init(num_channels: i32)\n"
        "    fn mixer_poll(out: *i16, nsamples: i32)\n}\n\n"
        "static music: xm64player_t = undefined\n\n"
        "fn init_music() {\n"
        "    audio.init(44100, 4)\n"
        "    -- music may need many channels (8-16 typical for XM)\n"
        "    mixer_init(16)\n"
        "    xm64player_open(&music, \"music/theme.xm64\")\n"
        "    xm64player_set_loop(&music, true)\n"
        "    xm64player_play(&music, 0)  -- start at channel 0\n}\n\n"
        "fn stop_music() {\n    xm64player_stop(&music)\n}\n\n"
        "-- in game loop:\nlet buf: *i16 = audio.get_buffer()\n"
        "if buf != none { mixer_poll(buf, 735) }\n```\n\n"
        "XM64 plays tracker music (XM/MOD format). The music uses mixer channels "
        "starting from first_channel. Leave higher channels free for sound effects.")

    add("How do I play music and sound effects simultaneously in Pak?",
        "Reserve lower mixer channels for music, higher channels for SFX:\n\n"
        "```pak\n-- channel allocation:\n"
        "-- channels 0-7: music (XM64 can use up to 8+ channels)\n"
        "-- channels 8-15: sound effects\n\n"
        "const SFX_CHANNEL_START: i32 = 8\n"
        "static next_sfx_channel: i32 = 8\n\n"
        "fn init_all_audio() {\n"
        "    audio.init(44100, 4)\n    mixer_init(16)\n"
        "    xm64player_open(&music, \"music/bgm.xm64\")\n"
        "    xm64player_play(&music, 0)  -- music on channels 0-7\n"
        "    wav64_open(&sfx_hit, \"sfx/hit.wav64\")\n}\n\n"
        "fn play_sfx(sfx: *wav64_t) {\n"
        "    wav64_play(sfx, next_sfx_channel)\n"
        "    next_sfx_channel = next_sfx_channel + 1\n"
        "    if next_sfx_channel >= 16 {\n"
        "        next_sfx_channel = SFX_CHANNEL_START\n    }\n}\n```\n\n"
        "This round-robins SFX across channels 8-15. If a channel is already "
        "playing, the new sound replaces it.")

    add("How do I change music volume dynamically in Pak?",
        "```pak\nextern \"C\" {\n"
        "    fn xm64player_set_vol(player: *xm64player_t, vol: f32)\n}\n\n"
        "-- fade music volume during gameplay events:\n"
        "static music_vol: f32 = 1.0\n\n"
        "fn fade_music(target: f32, speed: f32, dt: f32) {\n"
        "    if music_vol < target {\n"
        "        music_vol = music_vol + speed * dt\n"
        "        if music_vol > target { music_vol = target }\n"
        "    } elif music_vol > target {\n"
        "        music_vol = music_vol - speed * dt\n"
        "        if music_vol < target { music_vol = target }\n"
        "    }\n    xm64player_set_vol(&music, music_vol)\n}\n\n"
        "-- usage: fade to 30% volume over time\nfade_music(0.3, 0.5, dt)\n"
        "-- usage: fade back to full\nfade_music(1.0, 0.5, dt)\n```")

    add("How do I synchronize game events to music in Pak?",
        "xm64 supports effect callbacks for music sync:\n\n"
        "```pak\nextern \"C\" {\n"
        "    fn xm64player_tell(player: *xm64player_t, patidx: *i32, row: *i32, secs: *f32)\n"
        "    fn xm64player_seek(player: *xm64player_t, patidx: i32, row: i32, tick: i32)\n}\n\n"
        "-- check current playback position:\n"
        "static current_pattern: i32 = 0\n"
        "static current_row: i32 = 0\n"
        "static current_time: f32 = 0.0\n\n"
        "fn check_music_position() {\n"
        "    xm64player_tell(&music, &current_pattern, &current_row, &current_time)\n"
        "    -- trigger events based on pattern/row:\n"
        "    if current_pattern == 4 and current_row == 0 {\n"
        "        -- boss entrance at pattern 4\n"
        "        spawn_boss()\n    }\n}\n```")

    add("How do I handle audio buffer filling correctly in Pak?",
        "The critical audio loop pattern:\n\n"
        "```pak\nuse n64.audio\n\nextern \"C\" {\n"
        "    fn mixer_poll(out: *i16, nsamples: i32)\n"
        "    fn audio_get_buffer_length() -> i32\n}\n\n"
        "fn audio_frame() {\n"
        "    -- get buffer length (varies by frequency and TV type)\n"
        "    let nsamples: i32 = audio_get_buffer_length()\n\n"
        "    let buf: *i16 = audio.get_buffer()\n"
        "    if buf == none { return }  -- always check\n\n"
        "    mixer_poll(buf, nsamples)  -- fills stereo interleaved\n}\n```\n\n"
        "Call `audio_frame()` every frame in your game loop. "
        "`audio_get_buffer_length()` returns the correct sample count for the "
        "current frequency and TV type (PAL vs NTSC).")

    add("What audio formats does libdragon support?",
        "| Format | File | Use Case |\n"
        "|---|---|---|\n"
        "| WAV64 (.wav64) | Converted from .wav | Sound effects, voice |\n"
        "| XM64 (.xm64) | Converted from .xm/.mod | Tracker music |\n"
        "| YM64 (.ym64) | Converted from .ym | Chiptune/YM2149 |\n"
        "| Raw PCM | Custom | Custom synthesis |\n\n"
        "WAV64 supports compression levels 0-3 (0=uncompressed, 3=highest). "
        "Higher compression saves ROM space but uses more CPU.\n\n"
        "XM64 is the most common music format for N64 homebrew. "
        "It supports instruments, patterns, effects, and looping.")

    add("How do I implement positional audio (3D sound) in Pak?",
        "N64 hardware is stereo only, but you can fake 3D audio with panning and volume:\n\n"
        "```pak\nextern \"C\" {\n"
        "    fn mixer_ch_set_vol_pan(ch: i32, vol: f32, pan: f32)\n}\n\n"
        "fn update_3d_sound(ch: i32, listener_x: f32, listener_y: f32,\n"
        "                   source_x: f32, source_y: f32) {\n"
        "    let dx: f32 = source_x - listener_x\n"
        "    let dy: f32 = source_y - listener_y\n"
        "    let dist_sq: f32 = dx * dx + dy * dy\n\n"
        "    -- volume falls off with distance squared\n"
        "    let max_dist_sq: f32 = 10000.0\n"
        "    let vol: f32 = 1.0 - dist_sq / max_dist_sq\n"
        "    if vol < 0.0 { vol = 0.0 }\n\n"
        "    -- pan based on x offset (-1 to 1 mapped to 0 to 1)\n"
        "    let pan: f32 = (dx / 100.0) + 0.5\n"
        "    if pan < 0.0 { pan = 0.0 }\n"
        "    if pan > 1.0 { pan = 1.0 }\n\n"
        "    mixer_ch_set_vol_pan(ch, vol, pan)\n}\n```")

    return pairs
