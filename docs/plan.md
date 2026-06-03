# skill_cast — Native Cast screen mirroring (Cast Streaming protocol), max performance

## Context

Obiettivo dell'utente: **screensharing del desktop sulla TV con la massima performance
(latenza quasi-zero), SENZA installare app di terze parti sulla TV**, da Arch Linux +
**Hyprland (Wayland)**.

Percorso già esplorato e scartato in questa sessione:
- **HLS via catt** (costruito e funzionante, `~/.local/bin/cast-screen`): host-initiated,
  100% autonomo, **ma latenza ~3s** — pavimento strutturale dell'HLS. Troppo per l'utente.
- **Sunshine/Moonlight** (~16-50ms): scartato perché **Moonlight è un'app di terze parti**
  sulla TV ed è client-initiated.
- **Miracast**: vecchio, host-initiated ma fragile e supporto Philips/WiFi-P2P incerto.

L'unico percorso **nativo-Cast + sub-secondo + nessuna app sulla TV** è il **protocollo
Cast Streaming / mirroring** — quello che Chrome usa per "Trasmetti desktop" (~100-300ms via
RTP), non l'HLS segmentato. La TV (Philips 43PUS9235, Google TV con Chromecast integrato)
espone **già** il receiver di mirroring `app_id 0F5096E8` ("Chrome Mirroring"): lo usiamo
noi, nessuna installazione lato TV. Costruiamo **noi** il *sender* su Linux.

## Verdetto di fattibilità (validato in ricerca + sonde)

- **Un sender custom verso un device retail funziona**: l'autenticazione Cast è
  unidirezionale — è il sender a verificare il receiver, **non viceversa**. Il Chromecast
  retail non autentica il sender → la nostra implementazione è accettata. (I problemi di auth
  documentati online riguardano chi costruisce un *receiver* finto: caso opposto.)
- **Codec**: il mirroring receiver negozia **VP8 + Opus** (storicamente; H264 possibile via
  OFFER/ANSWER). Abbiamo **`vp8_vaapi` in hardware** (oltre h264/vp9/av1), Intel iHD,
  `/dev/dri/renderD128` → encode realtime a CPU ~0.
- **Motore protocollo**: **openscreen** (Google, C++) implementa il Cast Streaming *sender*
  completo (castv2 TLS, OFFER/ANSWER, RTP con formato Cast, AES-128, RTCP/NACK, congestion
  control). NON è pacchettizzato (gli "openscreen" in AUR sono un screen-recorder omonimo) →
  va compilato da sorgente con **GN/Ninja** (`ninja/clang/cmake` presenti, **`gn` da
  bootstrappare**). Nessun sender di mirroring per Linux esiste già (greenfield).

## STATO: spike Fase 0 SUPERATO ✅

Validato end-to-end contro la TV reale (`cast_sender` di openscreen, build ok):
- la TV retail lancia l'app mirroring `0F5096E8` su comando del nostro sender;
- auth Cast ok (cert Google ufficiale accettato, niente `-d`);
- **video campione visto sullo schermo** dall'utente → media plane nativo funzionante.

Scartato come NON best-practice: infilare un FIFO live nel `cast_sender` stock (demo
file-based). Crasha (`MakeUniqueAVFormatContext`, segfault su frame-properties variabili) e fa
doppio/triplo transcode — non robusto, non max-performance.

## Architettura best-practice (fondata sull'API reale di openscreen)

Confine pulito: **noi** facciamo cattura+encode HW e costruiamo gli `EncodedFrame`;
**openscreen** fa framing/sequencing/RTP/AES/RTCP/trasporto. La libreria sender è
**codec-agnostica**: `Sender::EnqueueFrame(const EncodedFrame&)` accetta bitstream VP8 grezzo
in `EncodedFrame.data` (ByteView) → **possiamo iniettare VP8 VAAPI saltando libvpx**.

```
Hyprland output (eDP-1)
   │  wlr-screencopy (dmabuf, zero-copy, NIENTE portal)   [forward: ext-image-copy-capture-v1]
   ▼
VAAPI VPP  RGB→NV12   →   vp8_vaapi encode  (low-latency, keyframe-on-demand, bitrate da sessione)
   │  bitstream VP8 + timestamp
   ▼
EncodedFrame{ data, frame_id=Sender::GetNextFrameId(), rtp_timestamp(90kHz),
              reference_time, dependency=kKeyFrame|kDependent }
   ▼
openscreen Sender / SenderSession   (riuso LoopingFileCastAgent per connessione+negoziazione)
   ├─ castv2 TLS → TV:8009 ; LAUNCH 0F5096E8 ; OFFER/ANSWER
   └─ RTP Cast + AES-128 + RTCP  →  TV mirroring receiver
   ▼
TV mostra il desktop  (~100-300ms, niente app installata)
```

### Punti di riuso vs sostituzione (file in `openscreen/cast/`)
- **RIUSO** `standalone_sender/main.cc` (Environment/TaskRunner/UDP/connessione) e
  `standalone_sender/looping_file_cast_agent.{h,cc}` (LAUNCH app, virtual connection,
  `SenderSession` lifecycle, callback `OnNegotiated` → `ConfiguredSenders`).
- **SOSTITUISCO** `standalone_sender/looping_file_sender.{h,cc}` (demux file + libvpx) con
  un `ScreenMirrorSender`: cattura live → encode → `Sender::EnqueueFrame`, replicando la
  logica frame_id/rtp_timestamp/dependency vista in
  `standalone_sender/streaming_vpx_encoder.cc:392` (`SendEncodedFrame`).
- **API chiave** (verbatim): `streaming/public/sender.h:156` `EnqueueFrame`,
  `:137 GetNextFrameId`, `:124 NeedsKeyFrame`, `Observer::OnPictureLost` (PLI → forza IDR
  VAAPI); `streaming/public/encoded_frame.h` (struct); `streaming/public/sender_session.h:156`
  `Negotiate(audio_configs, video_configs)`; `streaming/capture_configs.h`
  (`VideoCaptureConfig{codec=kVp8, max_frame_rate, max_bit_rate, target_playout_delay}`).
- **Controllo banda**: `SenderSession::GetEstimatedNetworkBandwidth()` →
  `SetTargetBitrate` sul nostro encoder (pattern in `looping_file_sender.cc:81`).
- **Pacing/backpressure**: `Sender::GetInFlightMediaDuration` vs `GetMaxInFlightMediaDuration`.

Binario `cast-mirror` (C++), nuovo target GN dentro l'albero openscreen (riusa toolchain+deps),
linka `//cast/streaming:sender`, `//cast/common:public`, `//platform`, **libva** (+ wayland
client per wlr-screencopy). Audio opzionale: monitor PipeWire → **Opus** (riuso encoder Opus
di openscreen) come secondo stream.

## Artefatti

1. **`~/Workspace/skill_cast/`** — qui sì autoriamo il progetto (codice C++ + build), come
   suggerito dall'utente in apertura: è codice vero, versionabile, non un semplice SKILL.md.
   - `src/` (capture wlr-screencopy, encoder VAAPI, glue openscreen sender), `meson.build`
     o `CMakeLists.txt`, `third_party/openscreen` (submodule/build), `README.md`.
   - Output: `cast-mirror` installato in `~/.local/bin/`.
2. **`~/.claude/skills/skill_cast/SKILL.md`** — aggiornata: nuovo modo `stream` (Cast
   mirroring nativo, low-latency) come modo primario per il mirror; `cast-mirror start|stop|
   status`. `catt` resta per media/URL casting (host-initiated, ortogonale, utile). Il
   vecchio mirror HLS (`cast-screen`) **declassato a fallback** "no-app, ~3s, autonomo".

## Esecuzione a fasi (de-risking incrementale — best practice: prima correttezza, poi performance)

**Fase 0 — SPIKE protocollo.** ✅ FATTA. `cast_sender` di openscreen → video sulla TV reale.

**Fase 1 — Integrazione live con encoder NOTO (de-risk dell'API, non della performance).**
`cast-mirror` v0: riusa `LoopingFileCastAgent`, sostituisce la sorgente-file con un capturer
**ext-image-copy-capture (buffer shm → swscale I420)** che alimenta l'encoder
**`StreamingVpxEncoder` esistente** (libvpx, prende `VideoFrame` I420 → fa già `EnqueueFrame`).
Obiettivo: desktop **live** sulla TV con codice minimo, isolando l'integrazione openscreen
dalla complessità VAAPI. Gate: desktop live stabile, niente crash.

  STATO Fase 1 (diagnosi consolidata sul run reale, log `/tmp/mirror.log`): il path
  funziona — **28 frame video catturati, EndToEnd 402ms, pacchetti sani** — ma due difetti:

  - **Problema A — crash in teardown (causa certa, da fixare ORA).** Use-after-free:
    `OnCapturedFrame` gira sul thread del `ScreenCapturer` e fa `env_.task_runner().PostTask(...)`
    catturando `this`/`video_encoder_`. Quando il receiver chiude il socket
    (`FatalSSLError SYSCALL`) → `LoopingFileCastAgent::OnError` → `Shutdown()` →
    `screen_sender_.reset()` distrugge `ScreenMirrorSender` mentre lambda già accodate lo
    referenziano; il TaskRunner ne esegue una dopo la distruzione → SIGSEGV (gdb: frame#0 nella
    lambda di `OnCapturedFrame`). **Fix (idioma canonico di `util/weak_ptr.h` — è proprio il suo
    esempio):** aggiungere `WeakPtrFactory<ScreenMirrorSender> weak_factory_{this};` come
    **ultimo** membro di `screen_mirror_sender.h`; in `OnCapturedFrame` catturare
    `weak_factory_.GetWeakPtr()` invece di `this` e, nella lambda postata,
    `if (auto* self = weak.get()) { …EncodeAndSend… }`. Il deref avviene sul thread del task
    runner (lo stesso che esegue `~ScreenMirrorSender`) → contratto di thread-safety rispettato.
    Gli `Alarm` (`next_task_`, `audio_task_`) si cancellano da soli nel dtor → già sicuri. Il fix
    swscale-padding già applicato resta corretto ma NON era la causa (nessun overrun di lettura).
  - **Problema B — connessione cade dopo ~2s (diagnosi DOPO il fix A, non indovinare).**
    `AvgEncodeTimeMs` video **147ms**, ~11fps, EndToEnd 402ms (al limite del playout delay ~400ms);
    eDP-1 è 1920x1200@60 scala 1 → **non** è HiDPI: è semplicemente **libvpx software lento su
    questa CPU**. Ipotesi: starving del receiver per encode troppo lento. Verifica empirica dopo A
    (quanto sopravvive, se il drop SSL ricorre, correlazione con stalli encoder). Cura strutturale
    = Fase 2 (VAAPI); test rapido intermedio = scalare in swscale a 1280x720 e/o ridurre bitrate
    per isolare la causa prima di investire nel path HW.

**Fase 2 — Max performance: encode VAAPI zero-copy.**

  ⚠️ CORREZIONE HARDWARE (verificata con `vainfo`, NON assumere): l'iGPU di questa macchina
  (**i7-1165G7, Tiger Lake, iHD 26.x**) NON ha encode HW per VP8/VP9/AV1 — solo **VLD (decode)**
  per VP8. Gli unici `VAEntrypointEncSlice/EncSliceLP` disponibili sono **H.264 e HEVC** (+ MPEG2,
  JPEG). Quindi `vp8_vaapi` è **impraticabile** su questo hardware: la premessa originale era
  errata. → Per "veloce + nitido" via HW si **pivota a H.264** (`h264_vaapi`, c'è anche il
  low-power `EncSliceLP`, ottimo per bassa latenza).

  Conseguenze sul design:
  - openscreen è codec-agnostico su `Sender::EnqueueFrame`, ma il sender standalone NON ha un
    encoder H264 software (solo libvpx VP8/VP9 + libaom AV1). Quindi forniamo NOI `h264_vaapi` e
    iniettiamo i NAL grezzi in `EncodedFrame.data`, con frame_id/rtp_timestamp/dependency corretti.
  - `VideoCodec::kH264` esiste nello streaming layer; "h264" è mappato in `message_fields.cc` e
    l'OFFER lo supporta (`offer_messages.cc`, `MediaCapability::kH264`). `main.cc:124 ParseCodec`
    lo esclude solo perché manca l'encoder SW → da allargare.
  - **RISCHIO CRITICO da sondare PRIMA di scrivere l'encoder**: questa TV accetta H.264 nel
    mirroring OFFER/ANSWER? (storicamente VP8). Probe minimale: offrire kH264 e vedere se
    `OnNegotiated` riceve un `video_sender` non-null / l'app resta lanciata. Se la TV rifiuta H264
    → restiamo su VP8 software (libvpx) e l'unica leva è ottimizzare/ridimensionare.

  Path HW (dopo probe OK): ext-image-copy-capture **dmabuf** → import surface VAAPI → **VPP
  RGB→NV12** → **`h264_vaapi`** low-latency (no B-frame, GOP corto/IDR on-demand via
  `Sender::NeedsKeyFrame`/`Observer::OnPictureLost`, bitrate da `GetEstimatedNetworkBandwidth`) →
  `EncodedFrame` grezzo → `EnqueueFrame`. Target <300ms glass-to-glass, CPU ~0, **1080p nitido**.
  Gate: fluido e nitido a 1080p, CPU bassa.

  Lezione confermata in Fase 1: i frame encodati NON devono superare la risoluzione negoziata
  (max 1920x1080); a 1920x1200 il receiver lanciava l'app poi la chiudeva (~1-2s). A 720p stabile.

**Fase 3 — Rifiniture.** Audio Opus (monitor PipeWire → encoder Opus di openscreen),
riconnessione/scelta device, pacing/backpressure (`GetInFlightMediaDuration`), packaging
(PKGBUILD locale / install in `~/.local/bin`), wrapper skill `stream` + STEP 0.

---

## Fase 4 — Miglioramenti qualità/perf (richiesti dall'utente, 2026-06-03)

### Context
Il mirror H.264 hardware funziona ed è stato validato ("sembra tutto molto bene"): ~150ms,
1080p (1728x1080), ~4.6Mbps, encode 16-26ms/frame, 23-28fps, stabile. L'utente chiede *cosa
migliorare*. Lettura del codice → colli di bottiglia identificati con riscontro nei file (non
a intuito):
- **fps tetto da cattura, non encode**: `screen_capturer.h:102` cattura **shm a buffer singolo,
  serializzata** (un frame alla volta); l'encoder a 16-26ms reggerebbe ~40-60fps.
- **due copioni CPU per frame**: swscale RGB→NV12+scale `SWS_BILINEAR`
  (`screen_mirror_sender.cc:227`) e upload CPU→GPU `av_hwframe_transfer_data`
  (`h264_vaapi_encoder.cc:207`).
- **nitidezza limitata dal rate-control, non dal bitrate**: il fallback senza `low_power`
  riapre l'encoder **senza `rc_mode=CBR`** (`h264_vaapi_encoder.cc:141`) → RC driver-default
  che su contenuto statico scende a ~4.6Mbps benché `-m 20M`. `SetTargetBitrate` mid-stream è
  no-op (`.cc:34`).
L'utente ha scelto **tutti e quattro** gli interventi sotto. Ordine = rischio crescente.

### 4a — Nitidezza (effort basso, indipendente)
Obiettivo: immagine ferma e nitida anche in movimento, subito, senza toccare l'architettura.
- **RC deterministico**: in `h264_vaapi_encoder.cc EnsureInitialized`, nel ramo di *retry*
  (riga ~141, quello che parte dopo il fallimento di `low_power`), aggiungere comunque
  `rc_mode=CBR` via `AVDictionary` (oggi quel retry chiama `avcodec_open2(ctx_, codec, nullptr)`
  → nessun RC esplicito). Mantenere `bit_rate/rc_max_rate/rc_min_rate=bit_rate` +
  `rc_buffer_size` per CBR reale. Effetto atteso: il bitrate effettivo sale da ~4.6 verso
  `bandwidth_being_utilized_` (≈ `max_bitrate/2`), quindi più dettaglio costante.
- **Scaler**: `screen_mirror_sender.cc:201` `SWS_BILINEAR` → `SWS_LANCZOS` (downscale più
  nitido; resta il path CPU/fallback anche dopo lo zero-copy).
- Run consigliato `-m 16000000` (CBR ~8M a 1080p è abbondante; il controller di congestione
  cappa comunque a `-m`).

### 4b — Latenza 100ms (banale)
`looping_file_cast_agent.cc CreateAndStartSession`: `kMirrorPlayoutDelay{150}` → `{100}` per il
path screen. ~50ms in meno glass-to-glass. Verifica empirica sulla TV: se compaiono micro-stutter
su wifi, tornare a 120-130ms (il receiver negozia min/max playout delay; 100 dovrebbe essere
accettato).

### 4c — Audio reale (effort medio)
Oggi `SendSilentAudio` (`screen_mirror_sender.cc:152`) manda silenzio via timer 10ms.
Sostituire con cattura **PipeWire** del monitor del sink di default → campioni float reali in
`audio_encoder_.EncodeAndSend`.
- Nuovo file `audio_capturer.{h,cc}` (analogo a `screen_capturer`, self-contained, nessun tipo
  openscreen): `pw_stream` in cattura sul monitor, thread proprio, callback con buffer
  F32/stereo/48kHz (per combaciare con la config Opus).
- Consegna al main runner come per il video: `env_.task_runner().PostTask` con
  `weak_factory_.GetWeakPtr()` guard; sul main thread chiama `audio_encoder_.EncodeAndSend`
  con `reference_time` da `env_.now()` (timeline audio già gestita).
- Rimuovere/disattivare il timer di silenzio quando la cattura reale è attiva (fallback a
  silenzio se PipeWire non parte).
- `BUILD.gn`: aggiungere `audio_capturer.{cc,h}` ai sources e `"pipewire-0.3"` ai `libs`
  (+ `include_dirs` di pipewire/spa, via `pkg-config`).

### 4d-0 — Misura (scelta data-driven, 2026-06-03) ⏳ PROSSIMA FASE

**Context.** 4a/4b/4c + packaging + consolidamento sono FATTI e validati sulla TV (utente:
"ok audio perfetto"). Prerequisiti 4d verificati read-only oggi: build fresca (nessun sorgente
più recente del binario), symlink integri, `vainfo` conferma **VAAPI VideoProc (VPP)** +
**H264 EncSlice/EncSliceLP** → il path GPU è hardware-fattibile. Resta la 4d (perf), ma il
piano oggi fonde **due colli di bottiglia indipendenti con rischio diverso**, quindi —
scelta dell'utente — **prima misuriamo, poi decidiamo dove intervenire** (no "andiamo a caso").

Mappa seam confermata leggendo i file:
- **fps (~28)** limitato dalla **cattura shm a buffer singolo serializzata**: `OnFrameReady`
  (`screen_capturer.cc:242-254`) riusa un solo `wl_buffer_`/`pool_data_` (`screen_capturer.h:102`);
  il frame N+1 parte solo dopo l'encode di N. Fix candidato = **multi-buffer + pipelining**
  (rischio basso, niente dmabuf).
- **CPU** dai due copioni per frame: **swscale `SWS_LANCZOS`** 1920×1200→1080p
  (`screen_mirror_sender.cc:211-238`, Lanczos costoso) + **upload** `av_hwframe_transfer_data`
  (`h264_vaapi_encoder.cc:220`). Fix candidato = **dmabuf→VAAPI→VPP→`EncodeSurface`**
  (rischio alto, sotto in 4d).

**Cosa misurare e da dove (nessun nuovo collector — riusiamo quello di openscreen):**
1. **fps / EndToEnd / encode-time**: già emessi periodicamente nel sender log dal collector di
   statistiche integrato di openscreen (è la fonte dei numeri storici 28fps / 147ms / 402ms).
   `cast-mirror start`, poi leggere le righe di stats nel log (`~/.local/state/skill_cast/mirror.log`).
2. **CPU per-thread**: `top -H -p <pid>` o `pidstat -t -p <pid> 1` mentre gira → separa il
   **thread ScreenCapturer** (swscale Lanczos) dal **thread main TaskRunner** (upload + encode
   dispatch). Capture-thread alto ⇒ Lanczos domina ⇒ VPP/zero-copy paga; main-thread alto ⇒
   upload/encode dominano.
3. **Discriminatore del tetto fps** (instrumentazione minima e revertibile in `OnCapturedFrame`,
   `screen_mirror_sender.cc:182-251`): tre timestamp loggati ogni N frame — intervallo dal frame
   precedente, durata `sws_scale`, latenza fino al `PostTask`. Se *intervallo ≈ swscale+encode
   serializzati* ⇒ tetto = serializzazione ⇒ **pipelining vince**. Se *intervallo ≈ solo swscale*
   ⇒ già parzialmente pipelinato ⇒ serve **zero-copy** per la CPU.
   *Alternativa zero-codice (A/B):* un rebuild con `SWS_LANCZOS`→`SWS_BILINEAR` (o box 720p) e
   confronto fps: fps piatti ⇒ capture-bound (pipelining); fps su ⇒ swscale-bound (VPP).

**Regola di decisione (esplicita, da applicare dopo la misura):**
- fps capped da serializzazione **e** CPU bassa → **solo pipelining** (multi-buffer), niente
  dmabuf. Rischio minimo, probabilmente basta per la fluidità.
- CPU alta (Lanczos/upload dominano) **e** fps swscale-bound → **zero-copy completo** (4d sotto).
- entrambi → **pipelining prima** (quick win), poi zero-copy se la CPU resta alta.

**Output della fase:** una tabellina (fps, EndToEnd ms, encode ms, %CPU capture-thread, %CPU
main-thread, swscale ms) → sceglie il ramo, riportata all'utente prima di scrivere altro codice.

**File toccati (solo misura):** opzionale `screen_mirror_sender.cc` (3 righe di log timing,
revertibili) — oppure zero codice usando l'A/B bilinear/720p + `top -H`.

> NB: la fase di misura richiede un **run live** del sender (azione non-readonly) → si esegue
> fuori da plan mode. La validazione statica (build/symlink/VAAPI) è già passata oggi.

#### RISULTATO MISURA (2026-06-03, eseguita) ✅ + DECISIONE
Misurato live (instrumentazione temporanea su `OnCapturedFrame`, poi rimossa; `top -H`/`pidstat`):
- **Video già fluido: ~48 fps** @ 1728×1080, **0 frame rifiutati/droppati** (`EnqueueFrame`
  rejected = 0). Il "28 fps" del piano era **stale** (misura vecchia, pre-4a).
- **Costo CPU dominante = swscale `SWS_LANCZOS`**: ~9 ms/frame ≈ **60% di 1 core** sul thread
  cattura. HW encode+upload ~13% del main. Totale processo ~0,75 core ≈ **9% di 8 core** —
  modesto in assoluto.
- Latenza: RTT LAN ~110-146ms; con playout 100ms il sender capava l'RTT al playout.
- Audio: i "gap 200ms" erano i **beep intervallati** del test (silenzio tra l'uno e l'altro),
  non una regressione; il playback continuo è pulito (confermato dall'utente).

**Verdetto vs regola di decisione:** né pipelining né zero-copy sono giustificati ORA.
Pipelining-only richiedeva fps capped (falso: 48fps, 0 drop). Zero-copy richiedeva CPU alta
(Lanczos è il top cost ma il carico assoluto è basso e gli fps sono ottimi) → il **4d resta un
guadagno solo batteria/calore (~0,6 core) ad alto rischio**, NON un fix di fluidità → **rinviato,
non eseguito.**

**Micro-tuning low-risk eseguito (scelta utente):**
- `looping_file_cast_agent.cc` `kMirrorPlayoutDelay` **100→120ms** (toglie il capping RTT;
  verificato: 0 frame rifiutati, encoder @ 7.84 Mbps). FATTO.
- Audio-idle silence-fill: **scartato** dall'utente (rischio medio per caso inudibile).

### 4d — Zero-copy GPU (effort alto, ultimo, gated) — ESEGUITA SOLO SE LA MISURA LA GIUSTIFICA
Obiettivo: togliere i due copioni CPU per frame → verso 60fps, latenza/CPU giù. Tenere il path
CPU attuale come fallback (flag o fallback automatico su errore d'import).
1. **Cattura dmabuf** invece di shm: ext-image-copy-capture annuncia anche i constraint
   **linux-dmabuf** (eventi `dmabuf_format`/`dmabuf_device`). Bindare `zwp_linux_dmabuf_v1`,
   allocare un **GBM bo** su `/dev/dri/renderD128` in un formato offerto (XRGB/ARGB8888),
   esporlo come `wl_buffer` dmabuf, usarlo come buffer di cattura. A frame pronto → fd dmabuf.
   (Modifica a `screen_capturer.{h,cc}`: aggiungere un percorso buffer dmabuf accanto a shm,
   con la `Frame` che esporta fd/modifier/stride invece del puntatore CPU.)
2. **Import in VAAPI**: costruire un `AVFrame` `AV_PIX_FMT_DRM_PRIME` che referenzia il dmabuf
   e mapparlo a una surface VAAPI con `av_hwframe_ctx` (tipo DRM) + `av_hwframe_map` →
   `AV_PIX_FMT_VAAPI`. (iHD su Tiger Lake supporta DRM_PRIME→VAAPI: strada battuta.)
3. **VPP RGB→NV12 + scale su GPU**: la surface importata è BGRX a risoluzione nativa; l'encoder
   vuole NV12 al box 1080p. Conversione+scale via VAAPI VideoProc (`VAEntrypointVideoProc`
   presente in `vainfo`): o `VAProcPipelineParameterBuffer` manuale (no nuove dep, solo libva),
   o un mini-graph libavfilter `scale_vaapi=w:h:format=nv12` (più semplice ma tira dentro
   libavfilter). Preferenza: VPP manuale via libva per restare leggeri.
4. **Encoder**: aggiungere a `H264VaapiEncoder` un path `EncodeSurface(AVFrame* vaapi_frame, …)`
   che salta `av_hwframe_get_buffer`/`transfer_data` e passa la surface GPU direttamente a
   `avcodec_send_frame`. `screen_mirror_sender.cc` sceglie il path (zero-copy vs CPU) in base
   alla disponibilità dmabuf.
5. **Pipelining cattura** (collaterale, abilita gli fps alti): richiedere il frame successivo
   senza attendere la fine dell'encode del corrente (oggi serializzato a buffer singolo) — usare
   2-3 buffer dmabuf a rotazione in `screen_capturer`.
Rischi: il compositore deve annunciare i constraint dmabuf (Hyprland sì, in generale);
validare a step (cattura dmabuf → import → VPP → encode), tenendo il fallback shm/CPU.

### File toccati (Fase 4)
- `cast/standalone_sender/h264_vaapi_encoder.cc` (4a RC; 4d `EncodeSurface`) e `.h`
- `cast/standalone_sender/screen_mirror_sender.cc` (4a scaler; 4c rimozione silenzio/feed audio;
  4d scelta path) e `.h`
- `cast/standalone_sender/looping_file_cast_agent.cc` (4b playout 100ms)
- `cast/standalone_sender/screen_capturer.{h,cc}` (4d dmabuf + multi-buffer)
- `cast/standalone_sender/audio_capturer.{h,cc}` (4c, nuovi)
- `cast/standalone_sender/BUILD.gn` (4c pipewire; 4d eventuali gbm/libva)

### Verifica end-to-end (Fase 4)
1. **4a+4b**: un rebuild, run `out/Default/cast_sender -c h264 -m 16000000 192.168.1.228:8009
   "screen:eDP-1"`. Verdetto utente su nitidezza (deve salire) e latenza (~100ms, no stutter).
   Controllo log: `AvgEncodeTimeMs`, bitrate effettivo (deve avvicinarsi a ~8M).
2. **4c**: riprodurre audio sul desktop → deve uscire dalla TV in sync; verificare nessun
   underrun/drop nel log; stop pulito senza thread PipeWire residui.
3. **4d**: confronto fps (atteso verso 50-60) e CPU (`top` sul processo, atteso crollo) vs path
   CPU; cronometro a schermo filmato col telefono per la latenza; nessun frame-drop sostenuto a
   1080p; fallback automatico a shm/CPU se l'import dmabuf fallisce.

---

## Riuso da questa sessione

- **VAAPI low-latency**: i parametri encoder messi a punto per l'HLS (`h264_vaapi`,
  `/dev/dri/renderD128`, no B-frame, GOP corto) si trasferiscono al VP8 in `cast-mirror`.
- **Discovery/IP**: `catt scan` per IP del device (`192.168.1.228`), LAN IP `192.168.1.75`.
- **`~/.local/bin/cast-screen`** resta come fallback HLS funzionante (ufw + CORS + LIVE già
  risolti) — non si butta nulla.
- **firewalld→ufw**: regole già impostate; il Cast Streaming usa UDP/RTP effimero — verificare
  che ufw non blocchi le porte RTP negoziate (eventuale regola LAN-scoped).

## Verifica end-to-end

1. **Fase 0**: ✅ video campione visibile sulla TV — protocollo OK contro questo device.
2. **Fase 1**: `cast-mirror` (libvpx) → desktop **live** sulla TV, stabile, niente crash.
3. **Fase 2**: con VAAPI → latenza <300ms (cronometro a schermo filmato col telefono), CPU
   bassa, nessun frame-drop sostenuto a 1080p.
4. **Stop pulito**: `cast-mirror stop` → receiver torna idle, nessun processo/porta residui.
5. **Regressione Cast**: `catt cast <url>` (media) continua a funzionare in parallelo.

## Rischi (espliciti)

- ~~Accettazione OFFER dal receiver retail~~ → **RISOLTO** dallo spike Fase 0 (video visto).
- ~~Build openscreen~~ → **FATTO** (gn da `extra`, gclient sync + ninja ok, `cast_sender` gira).
- **Integrazione live (Fase 1)**: timestamp/frame_id/dependency corretti verso `EnqueueFrame`;
  mitigato riusando l'encoder libvpx esistente prima di passare a VAAPI.
- **VAAPI VP8 (Fase 2)**: import dmabuf + VPP RGB→NV12 + `vp8_vaapi` low-latency da mettere a
  punto; fallback = restare su libvpx (Fase 1 già funzionante) se la performance basta.
- **Lezione**: NON riusare `cast_sender` stock con input FIFO (demo file-based → crash,
  doppio transcode). La via corretta è la libreria `//cast/streaming:sender`.
- **Effort**: progetto C++ multi-giornata, non un singolo file. Le fasi tengono il rischio
  incrementale e lo spike è il gate.
- **Fallback garantito**: se il nativo si rivela impraticabile, l'HLS `cast-screen` (~3s,
  autonomo, zero app) resta pienamente funzionante.

---

## Consolidamento sessione (2026-06-03) — progetto + memorie + discoveries

### Context
A valle della misura 4d-0 e del micro-tuning (playout 120ms), l'utente chiede di **consolidare
tutto**: progetto, memorie e discoveries. Survey read-only dei tre archivi → stato:
- **Progetto** `~/Workspace/skill_cast/`: README.md, skill/SKILL.md, bin/cast-mirror aggiornati
  oggi (✓). Unico stale: **`docs/plan.md`** (snapshot 01:28, pre-misura) fuori sync col piano
  canonico. Niente git repo (vendored 4.7GB → fuori scope, non si versiona).
- **Memorie** (auto-memory `…-Workspace-skill-cast/memory/`): `skill-cast-native-mirror.md` già
  aggiornata oggi con la misura; MEMORY.md allineato (✓). Solo cross-link da aggiungere.
- **Discoveries** (`~/personal/50-knowledge/`): **nessuna nota** su cast/vaapi/openscreen/pipewire.
  Gap reale → l'utente ha approvato la promozione di **working-style + research tecnica**.

Schema verificato dalle note esistenti (replico senza derive): working-style `active` → nota nel
vault + card `kb_<n>.md` nella memoria globale `-home-gianluca/memory/` + riga in quel MEMORY.md;
research `active` → solo nota vault, `card: null`; `_index.md` è auto-dataview (NESSUN edit manuale).

### Azioni (tutte fuori plan mode)

**A. Progetto — refresh snapshot**
- Copiare il piano canonico `~/.claude/plans/stiamo-progettando-una-skill-enchanted-nova.md`
  (questo file, con la sezione 4d-0 + questo Consolidamento) su
  `~/Workspace/skill_cast/docs/plan.md`, riallineando lo snapshot.

**B. Memorie — cross-link**
- `…-Workspace-skill-cast/memory/skill-cast-native-mirror.md`: aggiungere una riga che punta alle
  due nuove note di knowledge (tracciabilità memoria↔corpus). MEMORY.md resta invariato.

**C. Discoveries — promozione nel corpus (working-style + research)**

C1. **Working-style** (doctrine cross-progetto, con card always-on):
- Nuova nota vault `~/personal/50-knowledge/working-style/ws-measure-before-optimizing.md`
  (`kind: working-style`, `status: active`, `card: ws-measure-before-optimizing`,
  `source: [session:<id>, consolidate:2026-06-03]`). Tesi: **misura/verifica le assunzioni di
  performance prima di impegnarti in un'ottimizzazione ad alto rischio.** Esempio concreto:
  si credeva 28fps (numero stale), la misura ne ha dati **48** con 0 drop → l'intera
  giustificazione del 4d zero-copy crollava (restava solo batteria) → rinviato. Collega
  `[[ws-correctness-over-workarounds]]`, `[[ws-verify-contradictions]]`,
  `[[bp-protocol-level-diagnosis]]`.
- Card di recall `~/.claude/projects/-home-gianluca/memory/kb_ws-measure-before-optimizing.md`
  (`name: kb-ws-measure-before-optimizing`, `type: feedback`), corpo **Why/How to apply** +
  pointer alla nota vault + `[[kb-ws-correctness-over-workarounds]]`.
- Aggiungere la riga indice in `~/.claude/projects/-home-gianluca/memory/MEMORY.md`, sezione
  «## Knowledge cards (working-style, indicizzate)».

C2. **Research tecnica** (vault-only, no card):
- Nuova nota `~/personal/50-knowledge/research/ref-cast-streaming-linux-sender.md`
  (`kind: research`, `status: active`, `card: null`). Fatti riusabili verificati su hardware:
  auth Cast **unidirezionale** (un sender custom è accettato dal Chromecast retail); **openscreen**
  = motore sender codec-agnostico (`Sender::EnqueueFrame`); **VAAPI Tiger Lake/iHD** = encode solo
  **H.264/HEVC**, e per H.264 **solo CQP** (no CBR/VBR); i frame non devono superare la risoluzione
  negoziata; cattura audio **PipeWire monitor** con **timeline sample-accurate + re-anchor**
  (batte sia wall-clock che sample-count puri); **RTP sender-initiated → nessun firewall**;
  numeri misurati (~48fps @1728×1080, ~120ms, swscale Lanczos = costo CPU dominante). Collega
  `[[bp-protocol-level-diagnosis]]`.

### Verifica (post-esecuzione)
- `diff ~/.claude/plans/…nova.md ~/Workspace/skill_cast/docs/plan.md` → identici.
- Le due note vault hanno frontmatter valido (campi `type/kind/status/card/confidence/source/
  reviewed/created/updated`); compaiono nella dataview «Attive» di `_index.md`.
- La card `kb_ws-measure-before-optimizing.md` esiste e ha una riga in MEMORY.md globale →
  entra nel recall always-on (verifica: la riga è presente sotto la sezione cards).
- La memoria di progetto cita le due nuove note.
