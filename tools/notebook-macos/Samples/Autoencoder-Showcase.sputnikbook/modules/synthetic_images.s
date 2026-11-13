package synthetic_images

import torch
import plot
from notebook.ui import image, publish_images
from io import ByteBuffer

export generate_samples, publish_samples, prepare_samples

def rounded(value): Math.round(value * 1000) / 1000.0

# An uncompressed 8x8 RGB BMP in memory. Plot 0.2.0 decodes it once;
# its normalized PNG is also the exact image published to the carousels.
def sample_raster(pixels):
  buffer = ByteBuffer(246)
  buffer.put_all!(Hex.decode("424df600000000000000360000002800000008000000080000000100180000000000c0000000130b0000130b00000000000000000000"))
  8.times |row|:
    8.times |column|:
      index = ((7 - row) * 8 + column) * 3
      buffer.put!(pixels[index + 2]).put!(pixels[index + 1]).put!(pixels[index])
  plot.image(buffer.bytes)

# Measure distance to the contour in pixels, so flattening the ellipse keeps
# its stroke visible. A normalized ellipse equation would also squash it.
def ellipse_segments(radius, axis_ratio):
  points = []
  64.times |step|:
    phase = step * 2 * Math.PI / 64.0
    points.push!([radius * Math.cos(phase), radius * axis_ratio * Math.sin(phase)])
  segments = []
  points.each_with_index |point, index|:
    next_point = points[(index + 1) % points.count]
    dx = next_point[0] - point[0]
    dy = next_point[1] - point[1]
    segments.push!([point[0], point[1], dx, dy, dx * dx + dy * dy])
  segments

def contour_distance(x, y, segments):
  nearest_squared = 256.0
  segments.each |segment|:
    dx = x - segment[0]
    dy = y - segment[1]
    along = Math.max(0.0, Math.min(1.0, (dx * segment[2] + dy * segment[3]) / segment[4]))
    ex = dx - along * segment[2]
    ey = dy - along * segment[3]
    nearest_squared = Math.min(nearest_squared, ex * ex + ey * ey)
  Math.sqrt(nearest_squared)

def make_sample(kind, values, index):
  angle = if kind == :stripe:
    (values[0] * 140 - 70) * Math.PI / 180.0
  else:
    values[0] * Math.PI
  offset = values[1] * 3.2 - 1.6
  radius = 0.5 + values[2] * 3.5
  # A mild bias toward flatter ellipses; b/a can reach 0.01 (almost a line).
  axis_ratio = 0.01 + 0.99 * values[1] ** 1.7
  cx = 3.5 + (values[3] * 2 - 1) * 0.8
  cy = 3.5 + (values[4] * 2 - 1) * 0.8
  segments = if kind == :ring: ellipse_segments(radius, axis_ratio) else: []
  cosine = Math.cos(angle)
  sine = Math.sin(angle)
  color = if kind == :stripe:
    [190, 90, 120]
  else:
    [230, 160, 100]
  pixels = []
  8.times |y|:
    8.times |x|:
      distance = if kind == :stripe:
        ((x - 3.5) * cosine + (y - 3.5) * sine - offset).abs
      else:
        dx = x - cx
        dy = y - cy
        contour_distance(dx * cosine + dy * sine, -dx * sine + dy * cosine, segments)
      # Soft edges make subpixel shifts visible even at 8x8 resolution.
      coverage = Math.max(0.0, Math.min(1.0, (1.15 - distance) / 0.7))
      color.each |channel|: pixels.push!(Math.round(channel * coverage).int)
  caption = if kind == :stripe:
    "Полоска ##{index + 1} · нормаль #{rounded(angle * 180 / Math.PI)}° · смещение #{rounded(offset)} px"
  else:
    "Кольцо ##{index + 1} · d = #{rounded(radius * 2)} px · b/a = #{rounded(axis_ratio)} · поворот #{rounded(angle * 180 / Math.PI)}° · центр (#{rounded(cx)}, #{rounded(cy)})"
  features = pixels.map |value|: value / 255.0
  {kind:, features:, png: sample_raster(pixels).png, caption:}

def generate_samples(per_class: 48, seed: 7):
  unless Int === per_class and per_class >= 2 and per_class <= 64:
    raise ValueError("per_class must be an integer in 2..64 (carousel capacity)")
  random = torch.rand([per_class * 2, 5], seed:).to_a
  samples = []
  per_class.times |index|:
    samples.push!(make_sample(:stripe, random[index * 2], index))
    samples.push!(make_sample(:ring, random[index * 2 + 1], index))
  samples

def publish_samples(samples):
  [:stripe, :ring].each |kind|:
    frames = samples.filter |sample|: sample[:kind] == kind
    frames = frames.map |sample|: image(sample[:png], caption: sample[:caption])
    channel = if kind == :stripe:
      "stripes"
    else:
      "rings"
    publish_images(channel, frames, caption: "#{frames.count} семплов · 8×8 RGB · чёрный фон")
  samples.count

def prepare_samples(samples):
  samples.map |sample|:
    {kind: sample[:kind], features: sample[:features],
      raster: plot.image(sample[:png]), caption: sample[:caption]}
