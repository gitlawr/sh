#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# convert pdf to png, as lpr cannot recoginze chinese.
# - brew install imagemagick
# - lpstat -p lists all printers
# - lpoptions -p Canon_iR_C3020 -l lists all printer-specific options

for f in *.pdf; do
  id="${f%.*}"

  echo "converting ${f}"
  convert -density 600 -quality 100 "${f}" "${id}-%04d.png"

  echo "printing ${id}-*.png"
  lpr -P Canon_iR_C3020 -o media=A5 "${id}"-*.png;

  sleep 1
done
