# Image Inference Implementation Guide

## Overview

This document explains the implementation of image inference in the Apex Lite project using Gemma 4 and flutter_gemma v0.14.5+. The implementation follows the guidelines specified in `@gemma_supreme.md` and `broletestupdate.md`.

## Key Components

### 1. Main Application Initialization

The `main.dart` file properly initializes the FlutterGemma engine:

```dart
// Initialize FlutterGemma engine (required for Gemma 4)
await gemma.FlutterGemma.initialize(
  huggingFaceToken: const String.fromEnvironment('HUGGINGFACE_TOKEN'),
  maxDownloadRetries: 10,
  webStorageMode: gemma.WebStorageMode.streaming,
);
```

### 2. Local Inference Service

The `local_inference_service.dart` handles the core image processing logic:

#### Image Processing Flow

1. **Image Detection**: The service detects image messages by checking if `Message.imagePath` is present
2. **Image Loading**: Images are loaded as `Uint8List` bytes for processing
3. **Token Budgeting**: Visual token budgeting is applied based on image analysis needs:
   - Low budget (70-280 tokens) for basic classification
   - High budget (560-1120 tokens) for detailed analysis/OCR
4. **Message Creation**: Images are properly formatted using `gemma.Message.withImage()`

### 3. UI Integration

The `gajraj_scaffold.dart` handles image picking and display:

1. **Image Picking**: Uses `ImagePicker` to select images from gallery
2. **Image Conversion**: Converts images to `Uint8List` for proper processing
3. **UI Display**: Shows images in the chat interface with proper metadata

### 4. Core Processing

The `aether_core.dart` processes input events and creates proper `Message` objects:

1. **Input Event Handling**: Properly identifies image input events
2. **Message Creation**: Creates `Message` objects with `imagePath` for image messages
3. **Processing Flow**: Routes messages to the inference service for processing

## Implementation Details

### Variable Image Resolution (Visual Token Budget)

The implementation follows the guidelines for Variable Image Resolution:

```dart
// Apply visual token budgeting based on image analysis needs
if (m.content.toLowerCase().contains('detailed') || 
    m.content.toLowerCase().contains('ocr') || 
    m.content.toLowerCase().contains('text') ||
    m.content.toLowerCase().contains('read')) {
  // High budget for detailed analysis (560-1120 tokens)
} else {
  // Low budget for basic classification (70-280 tokens)
}
```

### Memory Management

The implementation follows best practices for memory management:

1. **Proper Disposal**: Image bytes are managed properly to prevent memory leaks
2. **Zombie Prevention**: Stream subscriptions are properly cancelled when the chat is closed
3. **Garbage Collection**: Old image data is properly disposed of

## Testing

To test the image inference implementation:

1. Run the application
2. Select a model (ensure it's a Gemma 4 model with `.litertlm` format)
3. Click the image button in the chat interface
4. Select an image from your device
5. Observe the image being processed and analyzed by the model

## Future Improvements

1. **Enhanced Token Budgeting**: Implement more sophisticated token budgeting based on image content analysis
2. **Performance Optimization**: Add caching mechanisms for frequently processed images
3. **Error Handling**: Implement more robust error handling for image processing failures
4. **Accessibility**: Add accessibility features for visually impaired users

## Compliance

This implementation complies with:
- `@gemma_supreme.md` guidelines
- `broletestupdate.md` requirements
- flutter_gemma v0.14.5+ best practices
- Riverpod 3.0 state management patterns
- Native Function Calling for autonomous agents