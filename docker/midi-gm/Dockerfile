# General MIDI synthesizer for the simulation.
#
# The firmware writes MIDI bytes into a FIFO under the bind-mounted project
# directory; this image reads them and plays them, so the same song can be
# heard on a GM instrument instead of the four-voice APU. That separates
# "the player is wrong" from "the APU cannot fit this music".
#
# Audio leaves through the same PulseAudio socket the SDL display uses.
FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ruby \
        fluidsynth \
        fluid-soundfont-gm \
    && rm -rf /var/lib/apt/lists/*

# tools/ and fmruby-core/ are bind-mounted by compose.
WORKDIR /work
CMD ["ruby", "/tools/fmrb_midi_monitor.rb", \
     "--fifo", "/project/midi_out.fifo", \
     "--fluidsynth", \
     "--soundfont", "/usr/share/sounds/sf2/FluidR3_GM.sf2"]
