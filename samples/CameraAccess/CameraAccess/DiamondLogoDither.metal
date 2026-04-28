#include <metal_stdlib>

using namespace metal;

namespace {

constant float kThirtyDegrees = 0.52359877559;
constant float kPixelGrey = 37.0 / 255.0;

constant float kBayer4x4[16] = {
  0.0, 8.0, 2.0, 10.0,
  12.0, 4.0, 14.0, 6.0,
  3.0, 11.0, 1.0, 9.0,
  15.0, 7.0, 13.0, 5.0,
};

float2 rotatePoint(float2 point, float angle) {
  float s = sin(angle);
  float c = cos(angle);
  return float2(c * point.x - s * point.y, s * point.x + c * point.y);
}

float roundedBoxSDF(float2 point, float2 halfSize, float radius) {
  float2 q = abs(point) - halfSize + radius;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

float bayerThreshold(int2 pixelPosition) {
  int x = (pixelPosition.x % 4 + 4) % 4;
  int y = (pixelPosition.y % 4 + 4) % 4;
  return (kBayer4x4[y * 4 + x] + 0.5) / 16.0;
}

}  // namespace

[[ stitchable ]] half4 diamondLogoDither(
  float2 position,
  half4 currentColor,
  float2 size,
  float2 center,
  float motifSize,
  float baseSeparation,
  float maxSeparation,
  float time,
  float animationSpeed,
  float opacity,
  float pixelScale
) {
  float phase = 0.5 + 0.5 * sin(time * animationSpeed);
  float separation = mix(baseSeparation, maxSeparation, phase);
  float2 axis = normalize(float2(cos(kThirtyDegrees), -sin(kThirtyDegrees)));

  float2 rearCenter = center - axis * separation * 0.5;
  float2 frontCenter = center + axis * separation * 0.5;

  float2 rearPoint = rotatePoint(position - rearCenter, -kThirtyDegrees);
  float2 frontPoint = rotatePoint(position - frontCenter, -kThirtyDegrees);

  float halfExtent = motifSize * 0.5;
  float cornerRadius = motifSize * 0.172;
  float antiAlias = max(1.0, pixelScale * 0.75);

  float rearSDF = roundedBoxSDF(rearPoint, float2(halfExtent), cornerRadius);
  float frontSDF = roundedBoxSDF(frontPoint, float2(halfExtent), cornerRadius);

  float outlineThickness = motifSize * 0.064;
  float outlineMask = 1.0 - smoothstep(
    outlineThickness - antiAlias,
    outlineThickness + antiAlias,
    abs(rearSDF)
  );
  outlineMask *= smoothstep(motifSize * 1.08, motifSize * 0.22, length(position - rearCenter));

  float fillMask = smoothstep(antiAlias, -antiAlias, frontSDF);
  float fillRadial = smoothstep(motifSize * 0.88, motifSize * 0.14, length(position - frontCenter));
  float fillBrightness = fillMask * mix(0.44, 0.94, fillRadial);

  float brightness = max(outlineMask * 0.92, fillBrightness);
  if (brightness <= 0.001) {
    return currentColor;
  }

  float2 samplePosition = floor(position / max(pixelScale, 1.0));
  float threshold = bayerThreshold(int2(samplePosition));
  if (brightness <= threshold) {
    return currentColor;
  }

  float blend = clamp(opacity * max(brightness, 0.32), 0.0, 1.0);
  float3 grey = float3(kPixelGrey);
  float3 mixed = mix(float3(currentColor.rgb), grey, blend);

  return half4(half3(mixed), currentColor.a);
}
