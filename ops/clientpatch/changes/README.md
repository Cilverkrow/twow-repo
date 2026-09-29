# Our client changes (deltas)

Deltas live in `changes/<Dbc>/NNNN_<description>.csv`: one directory per DBC,
with the files applied in name order. The format is described in
[the README](../README.md), section "Delta format". Only values we author go
here, never extracted tables.

This directory is empty on purpose in stage 1. The first deltas arrive with
stage 2 (shaman and rogue talents, #357/#367).
