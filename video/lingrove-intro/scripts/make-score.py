"""Original, deterministic 100-BPM score and foley for the synthetic product film.

No sampled music or external media: numpy synthesizes soft electric-piano harmonics,
bass, brushed ticks and editorial swells. The director uses 2.4-second bar boundaries.
The output is a local asset; neither synthesis nor rendering touches the native app.
"""
from pathlib import Path
import math
import subprocess
import wave
import numpy as np

RATE, DURATION = 44100, 50.4
mix = np.zeros((int(RATE * DURATION), 2), dtype=np.float64)
rng = np.random.default_rng(2718)

def add(at, signal, gain=1, pan=0):
    start = round(at * RATE)
    end = min(len(mix), start + len(signal))
    if end <= start:
        return
    mono = signal[:end-start] * gain
    mix[start:end, 0] += mono * math.sqrt((1-pan)/2)
    mix[start:end, 1] += mono * math.sqrt((1+pan)/2)

def note(at, midi, duration=1.7, gain=.07, pan=0, bass=False):
    t = np.arange(int(duration*RATE))/RATE
    f = 440*2**((midi-69)/12)
    attack = 1-np.exp(-t/(.025 if bass else .006))
    env = attack*np.exp(-t/(.55 if bass else .7)) * np.minimum(1,(duration-t)/.08)
    tone = np.sin(2*np.pi*f*t) + .26*np.sin(2*np.pi*f*2*t)*np.exp(-t*3)
    if not bass:
        tone += .12*np.sin(2*np.pi*f*3*t)*np.exp(-t*5)
        tone += .08*np.sin(2*np.pi*f*1.003*t)
    signal=tone*env
    add(at,signal,gain,pan)
    if not bass:
        add(at+.3,signal,gain*.18,-pan)
        add(at+.6,signal,gain*.08,pan)

def click(at, gain=.022, pan=0):
    t=np.arange(int(.04*RATE))/RATE
    noise=rng.normal(0,1,len(t))
    high=np.concatenate(([0],np.diff(noise)))
    add(at,(high*.35+np.sin(2*np.pi*1300*t)) * np.exp(-t*170),gain,pan)

def sweep(at, duration=.55, gain=.035):
    t=np.arange(int(duration*RATE))/RATE
    noise=rng.normal(0,1,len(t))
    soft=np.convolve(noise,np.ones(35)/35,'same')
    add(at,soft*np.sin(np.pi*t/duration)**2,gain*5)

# A sparse opening leaves room for the hesitation; the first full harmony lands at 4.8s.
for at, pitch in [(0,62),(1.2,69),(2.4,64),(3.6,66)]:
    note(at,pitch,gain=.075,pan=-.25)
chords=[[50,57,61,64,69],[47,54,57,62,66],[43,50,54,57,62],[45,52,57,59,64]]
for bar in range(2,21):
    start=bar*2.4
    chord=chords[((bar-2)//2)%4]
    energy=.65 if 11<=bar<=13 else 1.0
    if bar>=19:
        energy=.6
    note(start,chord[0],2.3,.13*energy,bass=True)
    for beat,idx in enumerate([1,3,2,4,2,3,1,4]):
        note(start+beat*.3,chord[idx]+12,1.7,.065*energy,pan=(-.35 if beat%2 else .35))
    for beat in range(4):
        click(start+beat*.6,.018*energy,pan=.25)
        if bar<19:
            t=np.arange(int(.22*RATE))/RATE
            phase=2*np.pi*(45*t+45*.035*(1-np.exp(-t/.035)))
            add(start+beat*.6,np.sin(phase)*np.exp(-t*22),.09*energy)

# UI and scene punctuation follows the exact scene-local action times.
for at in [6.4,7,7.6,8.2,12.9,15.2,27.8,33.2,37,39.3]:
    click(at,.05)
for at in [4.2,9.2,16.3,21.1,28.4,33.2,40.4,45.2]:
    sweep(at)
for at in [8.2,15.2,27.8,39.6,45.6]:
    note(at,81,.9,.07,pan=.1)
    note(at+.08,86,1.1,.045,pan=-.1)

# Fade in/out at the master, preserving musical dynamics below a conservative peak.
fade=np.minimum(1,np.arange(len(mix))/(RATE*.08))*np.minimum(1,(len(mix)-np.arange(len(mix)))/(RATE*1.4))
mix*=fade[:,None]
peak=float(np.max(np.abs(mix)))
mix*=.63/max(peak,1e-9)
out=Path(__file__).resolve().parents[1]/'public/audio/lingrove-score.wav'
with wave.open(str(out),'wb') as file:
    file.setnchannels(2)
    file.setsampwidth(2)
    file.setframerate(RATE)
    file.writeframes((mix*32767).astype('<i2').tobytes())
compressed=out.with_suffix('.m4a')
subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-i',str(out),'-c:a','aac','-b:a','192k',str(compressed)],check=True)
out.unlink()
print(f'{compressed}: {DURATION}s stereo; source peak {np.max(np.abs(mix)):.3f}')
