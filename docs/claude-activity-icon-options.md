# Claude Activity Icon Options

These are candidate SF Symbols for the small Claude activity/peak badge in the menu bar.

Current implementation:

- `arrow.down.circle.fill`

Where it is used:

- `JustaUsageBar/Views/AppDelegate.swift`

## Recommended Shortlist

1. `waveform.path.ecg`
   - Feels like live activity or motion.
   - Good if the badge should mean "currently in use".

2. `flame.fill`
   - Reads as hot/active/heavy usage.
   - Good if the badge should feel intense.

3. `bolt.fill`
   - Reads as fast/active/high throughput.
   - Good if the badge should feel dynamic but compact.

4. `arrow.down.right.circle.fill`
   - Keeps the "downward pressure" idea without looking identical to the current icon.
   - Good if the meaning is still "faster consumption".

5. `speedometer`
   - Reads as usage pace.
   - Good if the badge is specifically about burn rate.

## Full Option Set

1. `waveform.path.ecg`
   - Live activity, strong "in use" signal.

2. `flame.fill`
   - Heavy or hot usage.

3. `bolt.fill`
   - Fast activity.

4. `speedometer`
   - Pace or burn-rate oriented.

5. `arrow.down.right.circle.fill`
   - Downward pressure, more directional than the current icon.

6. `chart.line.downtrend.xyaxis`
   - Explicit consumption/downtrend metaphor.

7. `gauge.with.dots.needle.33percent`
   - Compact meter-like feel.

8. `timer`
   - Time-window pressure / active session feel.

9. `sparkles`
   - Lighter and friendlier, less "warning"-like.

10. `dot.radiowaves.left.and.right`
   - Ongoing activity / transmitting / active state.

## My Pick Order

1. `waveform.path.ecg`
2. `bolt.fill`
3. `speedometer`
4. `dot.radiowaves.left.and.right`
5. `flame.fill`

## Swap Notes

Current code path:

```swift
NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Claude peak hour")
```

If you pick one, I can swap it directly and tune the point size/weight so it still looks balanced in the menu bar.
