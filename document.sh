#!/bin/sh

# Check if filename is provided
if [ $# -eq 0 ]; then
  echo "Usage: $0 <pdf-file>"
  exit 1
fi

FILE="$1"

# Check if the file exists
if [ ! -f "$FILE" ]; then
  echo "Error: File '$FILE' not found."
  exit 1
fi

INFO=$(pdfinfo "$FILE" | grep "Page size")
WIDTH_PT=$(echo "$INFO" | awk '{print $3}')
HEIGHT_PT=$(echo "$INFO" | awk '{print $5}')

# Convert using bc
WIDTH_IN=$(echo "scale=2; $WIDTH_PT / 72" | bc)
HEIGHT_IN=$(echo "scale=2; $HEIGHT_PT / 72" | bc)

WIDTH_MM=$(echo "scale=2; $WIDTH_IN * 25.4" | bc)
HEIGHT_MM=$(echo "scale=2; $HEIGHT_IN * 25.4" | bc)

WIDTH_CM=$(echo "scale=2; $WIDTH_IN * 2.54" | bc)
HEIGHT_CM=$(echo "scale=2; $HEIGHT_IN * 2.54" | bc)

echo "Dimensions for '$FILE':"
echo "- Points:       ${WIDTH_PT} x ${HEIGHT_PT} pt"
echo "- Inches:       ${WIDTH_IN} x ${HEIGHT_IN} in"
echo "- Millimeters:  ${WIDTH_MM} x ${HEIGHT_MM} mm"
echo "- Centimeters:  ${WIDTH_CM} x ${HEIGHT_CM} cm"
