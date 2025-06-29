#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n'

export OMP_NUM_THREADS=$(nproc)
export MKL_NUM_THREADS=$OMP_NUM_THREADS
export MRTRIX_TMPFILE_DIR=/tmp

CKPT_PATH="/opt/ml/model/dti_best.pth"

DEVICE="cpu"
if command -v nvidia-smi >/dev/null 2>&1 && python - <<'PY' 2>/dev/null
import torch, sys; sys.exit(0 if torch.cuda.is_available() else 1)
PY
then DEVICE="cuda"; fi
echo "Using device: $DEVICE"

dwi_mha_files=$(find /input/images/dwi-4d-brain-mri -name "*.mha")

for dwi_mha in $dwi_mha_files; do
    # Set up file names
    json_file="/input/dwi-4d-acquisition-metadata.json"
    subj=$(basename "${dwi_mha%.*}")

    tmp=/tmp/${subj}
    mkdir -p "$tmp"
    bval="$tmp/${subj}.bval"
    bvec="$tmp/${subj}.bvec"
    nifti="$tmp/${subj}.nii.gz"
    mask="$tmp/${subj}_mask.nii.gz"
    tensor="$tmp/${subj}_tensor.nii.gz"

    echo "--> $subj : MHA→NIfTI"
    python3 convert_mha_to_nifti.py "$dwi_mha" "$nifti"
    python3 convert_json_to_bvalbvec.py "$json_file" "$bval" "$bvec"

    echo "--> $subj : skull-strip (BET)"
    bet "$nifti" "$tmp/bet" -m -f 0.2
    mv "$tmp/bet_mask.nii.gz" "$mask"

    echo "--> $subj : tensor fit"
    dwi2tensor "$nifti" "$tensor" \
        -mask "$mask" -fslgrad "$bvec" "$bval" \
        -nthreads $OMP_NUM_THREADS

    echo "--> $subj : extract feature"
    python3 stats_to_vector.py \
        --ckpt "$CKPT_PATH" \
        --tensor "$tensor" \
        --output "/output/features-128.json" \
        --device "$DEVICE"

    rm -rf "$tmp"
    echo "--> $subj done"
done