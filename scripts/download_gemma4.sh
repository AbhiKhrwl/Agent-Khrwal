#!/bin/bash

# Define colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Model URLs
MODEL_URL="https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm"
MODEL_NAME="gemma-4-E2B-it.litertlm"
DEST_DIR="models"

echo -e "${BLUE}=================================================${NC}"
echo -e "${BLUE}   Gemma 4 E2B Local Downloader for Apex Lite    ${NC}"
echo -e "${BLUE}=================================================${NC}"
echo ""
echo -e "Bro, ye script tumhara 2.59 GB ka model seedhe Mac pe download karegi."
echo -e "Isse baar-baar app me download nahi karna padega! \n"

# Create models directory if it doesn't exist
mkdir -p "$DEST_DIR"

# Check if model already exists
if [ -f "$DEST_DIR/$MODEL_NAME" ]; then
    echo -e "${GREEN}✅ Model already exists at $DEST_DIR/$MODEL_NAME${NC}"
    echo -e "Tum is file ko ModelPickerScreen me drag and drop kar sakte ho!"
    exit 0
fi

echo -e "Downloading ${MODEL_NAME} (2.59 GB)..."
echo -e "Please wait, this might take a few minutes depending on your internet speed.\n"

# Use curl to download with progress bar, following redirects (-L)
curl -L -C - -o "$DEST_DIR/$MODEL_NAME" "$MODEL_URL"

if [ $? -eq 0 ]; then
    echo -e "\n${GREEN}🚀 Download Complete!${NC}"
    echo -e "Model saved to: ${BLUE}$DEST_DIR/$MODEL_NAME${NC}"
    echo -e "\nAb emulator ya physical device run karo aur iss file ko"
    echo -e "ModelPickerScreen me DROP ZONE me daal do. Done! 😎"
else
    echo -e "\n${RED}❌ Download failed! Please check your connection and try again.${NC}"
    exit 1
fi
