// Copyright 2026 openduo
// SPDX-License-Identifier: FSL-1.1-Apache-2.0

#include "opus_shim.h"

const int POCKET_OPUS_SET_COMPLEXITY = OPUS_SET_COMPLEXITY_REQUEST;
const int POCKET_OPUS_SET_VBR = OPUS_SET_VBR_REQUEST;
const int POCKET_OPUS_SET_DTX = OPUS_SET_DTX_REQUEST;
const int POCKET_OPUS_SET_INBAND_FEC = OPUS_SET_INBAND_FEC_REQUEST;
const int POCKET_OPUS_SET_SIGNAL = OPUS_SET_SIGNAL_REQUEST;
const int POCKET_OPUS_GET_COMPLEXITY = OPUS_GET_COMPLEXITY_REQUEST;
const int POCKET_OPUS_GET_VBR = OPUS_GET_VBR_REQUEST;
const int POCKET_OPUS_GET_DTX = OPUS_GET_DTX_REQUEST;
const int POCKET_OPUS_GET_INBAND_FEC = OPUS_GET_INBAND_FEC_REQUEST;
const int POCKET_OPUS_SIGNAL_VOICE = OPUS_SIGNAL_VOICE;

int pocket_opus_encoder_set(OpusEncoder *enc, int request, int value) {
  return opus_encoder_ctl(enc, request, value);
}

int pocket_opus_encoder_get(OpusEncoder *enc, int request, int *value) {
  return opus_encoder_ctl(enc, request, value);
}
