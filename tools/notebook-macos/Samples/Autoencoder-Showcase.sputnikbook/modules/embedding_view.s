package embedding_view

import torch
import plot
from slowpilot.torch_som import SOM, plasma

export encode_samples, embedding_plot, embedding_som_plot

def encode_samples(model, samples, device: "cpu"):
  model.eval!
  torch.no_grad:
    rows = samples.map |sample|: sample[:features]
    features = torch.tensor(rows, dtype: "float32", device:)
    model.encode(features).to(device: "cpu").to_a

def embedding_plot(samples, codes, marker_size: 24):
  valid_codes = codes.all? |code|: code.count == 2
  raise ValueError("one 2D code is required per sample") unless codes.count == samples.count and valid_codes
  canvas = plot.figure(width: 1100, height: 820)
    .axes(x_label: "z1", y_label: "z2")
    .coordinates(aspect: :equal)
  samples.each_with_index |sample, index|:
    # Exact encoder coordinates: no jitter, PCA, labels or class offsets.
    canvas = canvas.image(sample[:raster], at: codes[index], width: marker_size)
  # Leave room for the thumbnails at the edges without moving their centers.
  xs = codes.map |code|: code[0]
  ys = codes.map |code|: code[1]
  x_pad = Math.max(0.05, (xs.max - xs.min) * 0.06)
  y_pad = Math.max(0.05, (ys.max - ys.min) * 0.06)
  canvas.domain(xs.min - x_pad, ys.min - y_pad, xs.max + x_pad, ys.max + y_pad)

def _euclidean_neighbor_distances(map):
  prototypes = map.weights.to_a
  width = map.width
  height = map.height
  Array.of(prototypes.count) |cell|:
    row = cell // width
    column = cell % width
    # Odd rows are shifted right by half a hexagon.
    diagonal = column + row % 2
    neighbors = [[column - 1, row], [column + 1, row],
      [diagonal - 1, row - 1], [diagonal, row - 1],
      [diagonal - 1, row + 1], [diagonal, row + 1]]
    total = 0.0
    count = 0
    neighbors.each |neighbor|:
      x = neighbor[0]
      y = neighbor[1]
      next unless x >= 0 and x < width and y >= 0 and y < height
      other = prototypes[y * width + x]
      squared = 0.0
      prototypes[cell].each_with_index |value, i|:
        squared += (value - other[i]) ** 2
      total += Math.sqrt(squared)
      count += 1
    total / Math.max(count, 1)

def embedding_som_plot(samples, codes, seed:, metric: :cosine):
  raise ValueError("one code is required per image") unless samples.count == codes.count
  embeddings = torch.tensor(codes, dtype: "float32")
  map = SOM(6, 5, metric:).fit!(embeddings, seed:)
  scale = if metric == :euclidean:
    {values: _euclidean_neighbor_distances(map), label: "Euclidean"}
  else:
    {values: map.neighbor_similarity.to_a, label: "Cosine"}
  canvas = map.hex_heatmap(scale[:values], palette: plasma(), label: scale[:label],
    width: 1100, height: 730)

  tiles = canvas.layers[0].data
  groups = Array.of(tiles.count): []
  assignments = map.predict(embeddings).to_a
  samples.each_with_index |sample, index|:
    groups[assignments[index]].push!(sample[:raster])

  scene = canvas.notebook_scene
  bounds = scene[:bounds]
  pixels_per_unit = scene[:frame][2] / (bounds[2] - bounds[0])
  groups.each_with_index |images, cell|:
    next if images.empty?
    ring = tiles[cell].outer
    xs = ring.map |point|: point.x
    ys = ring.map |point|: point.y
    x_range = xs.minmax
    y_range = ys.minmax
    center = [(x_range[0] + x_range[1]) / 2.0, (y_range[0] + y_range[1]) / 2.0]

    # Leave a band of visible Plasma color around the centered thumbnails.
    columns = Math.ceil(Math.sqrt(images.count)).to_int
    rows = (images.count + columns - 1) // columns
    step = (x_range[1] - x_range[0]) * pixels_per_unit * 0.65 / columns
    thumb_size = Math.min(42, step * 0.84)
    images.each_with_index |image, index|:
      row = index // columns
      row_count = Math.min(columns, images.count - row * columns)
      dx = (index % columns - (row_count - 1) / 2.0) * step
      dy = (row - (rows - 1) / 2.0) * step
      canvas = canvas.image(image, at: center, width: thumb_size, offset: [dx, dy])
  canvas
