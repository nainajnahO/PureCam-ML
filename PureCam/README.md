# PureCam

**An intelligent iOS camera app that learns your photography style**

![iOS](https://img.shields.io/badge/iOS-15.0+-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![SwiftUI](https://img.shields.io/badge/SwiftUI-4.0-green)
![ML](https://img.shields.io/badge/CoreML-On--Device-purple)

---

## What Does This App Do?

PureCam is a professional camera app for iPhone that **learns how you like to take photos** and automatically adjusts camera settings to match your style. Think of it as having a photography assistant that studies your preferences and prepares the camera exactly how you want it.

### The Problem It Solves

Most camera apps use generic automatic settings that work "okay" for everyone but great for no one. Professional photographers spend time manually adjusting two critical settings for every shot:

- **ISO** (how sensitive the camera is to light)
- **Shutter Speed** (how long the camera captures light)

PureCam eliminates this repetitive work by learning your personal preferences and predicting the perfect settings for each scene.

---

## How It Works (Non-Technical Explanation)

1. **You teach it**: Take 30+ photos while manually adjusting the camera settings the way you like them
2. **It learns**: When your phone charges overnight, the app trains a personal AI model on your preferences
3. **It assists you**: Next time you open the app, it automatically suggests settings based on what it learned from you
4. **You stay in control**: Don't like the suggestion? Adjust manually, and it learns from that too

The app captures **pure, unprocessed RAW photos** (professional format) with no artificial enhancement.

---

## What Makes This Project Impressive?

### 1. Machine Learning That Runs On Your Phone

Most AI apps send your data to cloud servers. PureCam does everything **privately on your device**:
- Analyzes scenes by extracting 13 different characteristics (brightness patterns, color temperature, contrast, etc.)
- Trains a custom AI model that learns the relationship between what you see and how you shoot
- Makes predictions in under 50 milliseconds—faster than you can blink

**Why this matters**: Demonstrates understanding of privacy, performance optimization, and cutting-edge mobile AI technology.

### 2. Smart About Relationships

The app doesn't just learn two settings independently, it understands that ISO and shutter speed work together (like balancing volume and bass on speakers). It uses **sequential prediction**: first decides ISO based on the scene, then chooses shutter speed based on both the scene *and* the ISO choice.

**Why this matters**: Shows ability to model complex real-world relationships, not just simple patterns.

### 3. Battery-Conscious Design

The app only trains the AI model when your phone is plugged in and charging: never draining your battery for background processing.

**Why this matters**: Demonstrates thoughtful user experience design and resource management.

### 4. Invisible Intelligence

There's no "AI mode" button or complicated settings. The AI works seamlessly in the background:
- Automatically applies predictions at startup
- Visually shows recommendations by animating control knobs
- Silently steps aside if you prefer manual control
- Falls back gracefully to standard auto-exposure if not enough data

**Why this matters**: Shows restraint and user-centered design: technology that helps without getting in the way.

### 5. Performance Engineering

The app processes high-resolution camera frames in real-time while:
- Extracting scene features in under 100ms
- Running AI predictions in under 50ms
- Using advanced mathematical techniques (vectorized computation) for speed

**Why this matters**: Demonstrates ability to optimize for mobile constraints (battery, processing power, memory).

---

## Technical Highlights

<details>
<summary>For technical summary (click to expand)</summary>

### Technologies Used
- **SwiftUI** - Modern declarative UI framework
- **AVFoundation** - Low-level camera control (RAW capture, manual exposure)
- **Core ML** - On-device machine learning
- **CreateML** - Model training with MLBoostedTreeRegressor
- **Accelerate Framework** - Hardware-accelerated math (vDSP for vectorized statistics)
- **Combine** - Reactive state management with @Observable pattern

### Architecture Decisions
- **Sequential prediction pipeline**: Two-stage ML (ISO → Shutter) to model coupled variables
- **FIFO training queue**: Max 500 samples with automatic pruning
- **Lazy loading**: Video frames buffered, features extracted on-demand
- **Inverse logarithmic mapping**: Mathematical precision for UI control calibration
- **State machine**: 6-state session management (.disabled, .ready, .inferring, .applied, .manualOverride, .error)

### Performance Metrics
- Feature extraction: <100ms (256x256 downsampling + Accelerate framework)
- ML inference: <50ms (BoostedTree on CPU+Neural Engine)
- Model size: <5MB
- Memory overhead: <100MB
- Training: ~10s for 100 samples (background, CPU-only)

### Code Quality
- Clean separation of concerns (data models, extraction, training, orchestration)
- Protocol-oriented design for testability
- Comprehensive error handling with graceful degradation
- No force-unwrapping, proper optional handling
- Battery state monitoring with NotificationCenter observers

</details>

---

## Skills Demonstrated

| Skill | How This Project Shows It |
|-------|---------------------------|
| **iOS Development** | Native app using latest SwiftUI and iOS 15+ APIs |
| **Machine Learning** | Custom on-device training pipeline with Core ML |
| **Computer Vision** | Real-time scene analysis from camera frames |
| **Performance Optimization** | Vectorized math, efficient memory management, <150ms startup |
| **UX Design** | Invisible AI, animated feedback, graceful fallbacks |
| **Problem Solving** | Solved coupling problem with sequential prediction |
| **System Design** | Clean architecture, state management, data persistence |
| **Resource Management** | Battery-aware training, memory-efficient processing |

---

## Why I Built This

As a photographer and developer, I was frustrated with:
1. **Generic auto-exposure** that doesn't match my creative vision
2. **Repetitive manual adjustments** for similar scenes
3. **Privacy concerns** with cloud-based AI assistants

PureCam combines my passions for photography and machine learning to create a tool that's both powerful and respectful of the user.

---

## Future Enhancements

- [ ] Histogram-based features (15 additional bins for finer tonal analysis)
- [ ] Scene classification (portrait, landscape, night, etc.)
- [ ] Multi-model ensemble for improved accuracy
- [ ] Export/import custom models (share your style with others)
- [ ] Analytics dashboard (show training progress and model performance)

---


## License
+ This project is licensed under the **GNU General Public License v3.0**. 
---

*Built with passion for photography and machine learning • 2025*