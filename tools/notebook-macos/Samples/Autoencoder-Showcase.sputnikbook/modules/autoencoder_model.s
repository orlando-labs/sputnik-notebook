package autoencoder_model

import torch
from torch.nn import Module, Sequential, Linear, ReLU

export Autoencoder

# 8x8 RGB -> 192 channels -> a code of exactly two numbers -> 192 channels.
class Autoencoder < Module:
  def init(seed: 7, device: "cpu"):
    raise ValueError("MPS unavailable; select CPU explicitly") if device == "mps" and not torch.mps_available?
    _initialize_registry!
    @encoder = Sequential([
      Linear(192, 64, seed:, device:), ReLU(),
      Linear(64, 16, seed: seed + 1, device:), ReLU(),
      Linear(16, 2, seed: seed + 2, device:)
    ])
    @decoder = Sequential([
      Linear(2, 16, seed: seed + 3, device:), ReLU(),
      Linear(16, 64, seed: seed + 4, device:), ReLU(),
      Linear(64, 192, seed: seed + 5, device:)
    ])

  def encode(x): @encoder(x)

  def decode(z): @decoder(z)

  def forward(x): decode(encode(x))

  def forward!(x): @decoder.call!(@encoder.call!(x))
