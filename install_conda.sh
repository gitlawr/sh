#!/bin/bash

echo "Downloading Miniconda..."
wget -O Miniconda3-latest-Linux-x86_64.sh https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh

echo "Installing Miniconda..."
bash Miniconda3-latest-Linux-x86_64.sh -b -p $HOME/miniconda3

echo "Configuring Conda..."
$HOME/miniconda3/bin/conda init bash

rm Miniconda3-latest-Linux-x86_64.sh

echo "✅ Installation completed! Re-open the shell and run:"
echo "   conda --version"
echo "to check."
