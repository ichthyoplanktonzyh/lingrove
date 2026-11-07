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

RATE, DURATION = 44100, 67.2
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

# Same original harmonic palette, with space around the first send/reply.
chords=[[50,57,61,64,69],[47,54,57,62,66],[43,50,54,57,62],[45,52,57,59,64]]
for bar in range(28):
    start=bar*2.4
    chord=chords[(bar//2)%4]
    energy=.4 if bar<2 or 10<=bar<=12 else .75
    if bar>=26: energy=.5
    note(start,chord[0],2.3,.12*energy,bass=True)
    for beat,idx in enumerate([1,3,2,4,2,3,1,4]):
        note(start+beat*.3,chord[idx]+12,1.6,.06*energy,pan=(-.3 if beat%2 else .3))
    if 2<=bar<26 and not 10<=bar<=12:
        for beat in range(4):
            t=np.arange(int(.22*RATE))/RATE
            phase=2*np.pi*(45*t+45*.035*(1-np.exp(-t/.035)))
            add(start+beat*.6,np.sin(phase)*np.exp(-t*22),.06)
music=mix.copy()
mix[:]=0
# Frame-addressed foley: button / Tab / Return / replacement / send / hover-lookup / save / enroll / reveal / rate.
for at in [5.1,8.4,9.1,9.8,15.3,17,22.6,25.2,32.05,42.0,48.2,50.3,52.6,55.0,61.9]:
    click(at,.08)
# Short keystroke beds stop at the end of each actual typing interval.
for start,end in [(6.6,7.2),(12,13.15),(13.75,15.15),(18,20.2),(57.4,60.9)]:
    for at in np.arange(start,end,.09):click(float(at),.025,pan=-.1)
for at,duration in [(2.7,.8),(5.5,.5),(12,.3),(18,.5),(25.2,.4),(27,.35),(30.3,.55),(37.75,.7),(43.8,.6),(52.25,.7),(56.4,.55),(62.4,.6)]:
    sweep(at,duration,.025)
foley=mix.copy()
folder=Path(__file__).resolve().parents[1]/'public/audio'
for name,data,peak in [('music',music,.38),('foley',foley,.48)]:
    fade=np.minimum(1,np.arange(len(data))/(RATE*.05))*np.minimum(1,(len(data)-np.arange(len(data)))/(RATE*1.1))
    data*=fade[:,None]
    data*=peak/max(float(np.max(np.abs(data))),1e-9)
    out=folder/f'first-hello-{name}.wav'
    with wave.open(str(out),'wb') as file:
        file.setnchannels(2);file.setsampwidth(2);file.setframerate(RATE)
        file.writeframes((data*32767).astype('<i2').tobytes())
    compressed=out.with_suffix('.m4a')
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-i',str(out),'-c:a','aac','-b:a','192k',str(compressed)],check=True)
    out.unlink()
    print(compressed)
