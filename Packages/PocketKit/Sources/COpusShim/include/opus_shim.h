// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

// Swift cannot call C variadic functions, and opus_encoder_ctl is one. These
// wrappers expose the few integer controls the app sets.
#ifndef POCKET_OPUS_SHIM_H
#define POCKET_OPUS_SHIM_H

#include <Opus/opus.h>

int pocket_opus_encoder_set(OpusEncoder *enc, int request, int value);
int pocket_opus_encoder_get(OpusEncoder *enc, int request, int *value);

// Request codes, re-exported as plain constants (the header defines them as macros).
extern const int POCKET_OPUS_SET_COMPLEXITY;
extern const int POCKET_OPUS_SET_VBR;
extern const int POCKET_OPUS_SET_DTX;
extern const int POCKET_OPUS_SET_INBAND_FEC;
extern const int POCKET_OPUS_SET_SIGNAL;
extern const int POCKET_OPUS_GET_COMPLEXITY;
extern const int POCKET_OPUS_GET_VBR;
extern const int POCKET_OPUS_GET_DTX;
extern const int POCKET_OPUS_GET_INBAND_FEC;
extern const int POCKET_OPUS_SIGNAL_VOICE;

#endif
