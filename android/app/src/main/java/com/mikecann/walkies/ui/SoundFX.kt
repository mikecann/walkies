package com.mikecann.walkies.ui

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

/**
 * The celebration's sound effects, made in code rather than shipped as files, like
 * SoundFX.swift (the iPhone bundles no sound files): soft "bloop" pops that climb a
 * pentatonic scale as tiles turn up, a bell chime for a secret, a little fanfare for
 * the summary and a tick for counting up. Played as sonification without asking for
 * audio focus, so they mix over a podcast rather than stopping it, and kept quiet
 * when the phone's on silent or vibrate, as the iPhone's silent switch does.
 */
class SoundFX(context: Context) {
    sealed interface Sound {
        /** The nth tile in a run, climbing in pitch. */
        data class Pop(val n: Int) : Sound
        data object Chime : Sound
        data object Fanfare : Sound
        data object Tick : Sound
    }

    private val audio = context.applicationContext.getSystemService(AudioManager::class.java)
    private val tracks = HashMap<Sound, AudioTrack>()
    private val attributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    /** Makes the sounds up front, so there's no lag on the first. Call off the main thread if you can. */
    fun prepare() {
        for (n in 0..14) track(Sound.Pop(n))
        track(Sound.Chime)
        track(Sound.Fanfare)
        track(Sound.Tick)
    }

    fun play(sound: Sound) {
        if (audio?.ringerMode != AudioManager.RINGER_MODE_NORMAL) return
        val key = if (sound is Sound.Pop) Sound.Pop(min(sound.n, 14)) else sound
        val track = track(key) ?: return
        runCatching {
            if (track.playState == AudioTrack.PLAYSTATE_PLAYING) track.stop()
            track.reloadStaticData()
            track.play()
        }
    }

    fun release() {
        synchronized(tracks) {
            tracks.values.forEach { runCatching { it.release() } }
            tracks.clear()
        }
    }

    private fun track(sound: Sound): AudioTrack? = synchronized(tracks) {
        tracks[sound] ?: runCatching { build(make(sound)) }.getOrNull()?.also { tracks[sound] = it }
    }

    private fun build(samples: ShortArray): AudioTrack {
        val track = AudioTrack.Builder()
            .setAudioAttributes(attributes)
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build(),
            )
            .setTransferMode(AudioTrack.MODE_STATIC)
            .setBufferSizeInBytes(samples.size * 2)
            .build()
        track.write(samples, 0, samples.size)
        track.setVolume(0.7f)
        return track
    }

    // Making the sounds, as in SoundFX.swift.

    private fun make(sound: Sound): ShortArray = when (sound) {
        is Sound.Pop -> {
            val step = min(sound.n, 14)
            val semitones = (step / 5) * 12 + PENTATONIC[step % 5]
            val f = 523.25 * 2.0.pow(semitones / 12.0)
            render(0.22) { t ->
                // A quick upward bend into the note, like a bubble.
                val bend = 1 - 0.25 * exp(-t * 60)
                val phase = 2 * PI * f * bend * t
                val envelope = min(1.0, t * 400) * exp(-t * 18)
                (sin(phase) + 0.25 * sin(2 * phase)) * envelope * 0.55
            }
        }
        Sound.Chime -> {
            // C6, E6, G6, C7 in turn, each a little bell.
            val notes = doubleArrayOf(1046.5, 1318.5, 1568.0, 2093.0)
            render(1.6) { t ->
                var sample = 0.0
                for ((i, f) in notes.withIndex()) {
                    val start = i * 0.09
                    if (t < start) continue
                    val u = t - start
                    val bell = sin(2 * PI * f * u) + 0.4 * sin(2 * PI * f * 2.76 * u) * exp(-u * 6) + 0.2 * sin(2 * PI * f * 5.4 * u) * exp(-u * 10)
                    sample += bell * min(1.0, u * 300) * exp(-u * 3.2) * 0.22
                }
                sample
            }
        }
        Sound.Fanfare -> {
            // A rising C major arpeggio that lands on a held chord.
            val arpeggio = doubleArrayOf(523.25, 659.25, 783.99)
            val chord = doubleArrayOf(523.25, 659.25, 783.99, 1046.5)
            render(1.8) { t ->
                var sample = 0.0
                for ((i, f) in arpeggio.withIndex()) {
                    val start = i * 0.11
                    if (t < start || t >= start + 0.3) continue
                    val u = t - start
                    sample += brass(f, u) * min(1.0, u * 200) * exp(-u * 8) * 0.3
                }
                if (t >= 0.33) {
                    val u = t - 0.33
                    for (f in chord) sample += brass(f, u) * min(1.0, u * 60) * exp(-u * 1.6) * 0.14
                }
                sample
            }
        }
        Sound.Tick -> render(0.04) { t -> sin(2 * PI * 2400 * t) * exp(-t * 160) * 0.25 }
    }

    /** A bright, slightly buzzy tone: a few odd and even harmonics. */
    private fun brass(f: Double, t: Double) =
        sin(2 * PI * f * t) + 0.5 * sin(4 * PI * f * t) + 0.25 * sin(6 * PI * f * t) + 0.12 * sin(8 * PI * f * t)

    private inline fun render(seconds: Double, sample: (Double) -> Double): ShortArray {
        val frames = (seconds * RATE).toInt()
        return ShortArray(frames) { i ->
            val t = i.toDouble() / RATE
            // A short fade at the very end so nothing clicks.
            val tail = min(1.0, (seconds - t) / 0.01)
            (max(-1.0, min(1.0, sample(t) * tail)) * Short.MAX_VALUE).toInt().toShort()
        }
    }

    companion object {
        private const val RATE = 44_100

        /** A major pentatonic scale from C5, so any run of pops sounds pleasant. */
        private val PENTATONIC = intArrayOf(0, 2, 4, 7, 9)
    }
}
