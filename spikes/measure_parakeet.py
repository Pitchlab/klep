"""Meet wat PL-690 nodig heeft: is een warme daemon nodig, en haalt streaming realtime?

Draai met HF_HUB_OFFLINE=1 om te bewijzen dat er geen netwerk aan te pas komt.
Verwacht twee wav-bestanden (16 kHz mono) als argument: kort en lang.
"""

import json
import resource
import sys
import time

MODEL = "mlx-community/parakeet-tdt-0.6b-v3"


def rss_mb() -> float:
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 * 1024)


def main() -> None:
    short_wav, long_wav = sys.argv[1], sys.argv[2]
    out = {"model": MODEL}

    t = time.perf_counter()
    import mlx.core as mx
    from parakeet_mlx import from_pretrained
    from parakeet_mlx.audio import load_audio
    out["import_s"] = round(time.perf_counter() - t, 3)

    t = time.perf_counter()
    model = from_pretrained(MODEL)
    out["model_load_s"] = round(time.perf_counter() - t, 3)
    out["rss_after_load_mb"] = round(rss_mb(), 1)

    # Koude start zoals de gebruiker hem ervaart: proces op, model geladen, eerste zin.
    t = time.perf_counter()
    first = model.transcribe(short_wav)
    out["first_transcribe_s"] = round(time.perf_counter() - t, 3)
    out["first_text"] = first.text.strip()

    # Warme runs: dit is wat elke volgende dictaat kost.
    warm = []
    for _ in range(3):
        t = time.perf_counter()
        model.transcribe(short_wav)
        warm.append(time.perf_counter() - t)
    out["warm_short_s"] = round(min(warm), 3)

    t = time.perf_counter()
    long_res = model.transcribe(long_wav)
    out["warm_long_s"] = round(time.perf_counter() - t, 3)
    out["long_text"] = long_res.text.strip()

    # Streaming: voer audio in stukjes van 0.5 s en meet wat elk stukje kost.
    # Onder realtime blijven is de eis; boven 0.5 s per stuk loopt hands-free achter.
    audio = load_audio(long_wav, model.preprocessor_config.sample_rate)
    hop = model.preprocessor_config.sample_rate // 2
    chunk_ms = []
    t_stream = time.perf_counter()
    with model.transcribe_stream(context_size=(256, 256)) as stream:
        for i in range(0, len(audio), hop):
            t = time.perf_counter()
            stream.add_audio(audio[i : i + hop])
            chunk_ms.append((time.perf_counter() - t) * 1000)
        out["stream_text"] = stream.result.text.strip()
    out["stream_total_s"] = round(time.perf_counter() - t_stream, 3)
    out["stream_chunks"] = len(chunk_ms)
    out["stream_chunk_ms_max"] = round(max(chunk_ms), 1)
    out["stream_chunk_ms_median"] = round(sorted(chunk_ms)[len(chunk_ms) // 2], 1)
    out["rss_peak_mb"] = round(rss_mb(), 1)

    print(json.dumps(out, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
