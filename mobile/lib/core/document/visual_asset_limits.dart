const maximumVisualAssetBytes = 8 * 1024 * 1024;
const maximumVisualAssetDimension = 4096;
const maximumVisualAssetPixels = 16 * 1024 * 1024;
const maximumVisualAssetDecodeDimension = 2048;
const maximumVisualAssetDecodePixels = 4 * 1024 * 1024;

bool validVisualAssetDimensions(int width, int height) =>
    width > 0 &&
    height > 0 &&
    width <= maximumVisualAssetDimension &&
    height <= maximumVisualAssetDimension &&
    width * height <= maximumVisualAssetPixels;
