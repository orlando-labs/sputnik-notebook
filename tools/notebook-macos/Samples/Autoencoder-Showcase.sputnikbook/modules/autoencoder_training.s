package autoencoder_training

import torch
from torch.nn import MSELoss
from torch.optim import Adam
from torch.data import TensorDataset, DataLoader
from progressbar import ProgressBar
from notebook.ui import publish_point

export train_autoencoder

def train_autoencoder(model, samples, device: "cpu", epochs: 600, batch_size: 32,
    learning_rate: 0.003, seed: 7):
  unless Int === epochs and epochs > 0 and Int === batch_size and batch_size > 0:
    raise ValueError("epochs and batch_size must be positive integers")
  raise ValueError("learning_rate must be in (0, 1]") unless learning_rate > 0 and learning_rate <= 1
  raise ValueError("at least four samples required") if samples.count < 4
  # Only pixels enter the dataset; no labels or generation parameters.
  rows = samples.map |sample|: sample[:features]
  features = torch.tensor(rows, dtype: "float32")
  batches = DataLoader(TensorDataset(features), batch_size:, shuffle: true, seed:)
  optimizer = Adam(model.parameters, lr: learning_rate)
  criterion = MSELoss()
  all_features = features.to(device:)
  initial_loss = torch.no_grad:
    criterion(model(all_features), all_features).item
  progress = ProgressBar(total: epochs * batches.count, desc: "Автоэнкодер · шаги Adam",
    throttle: 0.1, id: "autoencoder-training")
  step = 0
  last_loss = initial_loss
  started = Time.monotonic
  model.train!
  publish_point("reconstruction-loss", 0, initial_loss)
  epochs.times |epoch|:
    batches.sampler.set_epoch!(epoch)
    batches.each |batch_tuple|:
      batch = batch_tuple[0].to(device:)
      optimizer.zero_grad!
      loss = criterion(model.call!(batch), batch)
      loss.backward!
      optimizer.step!
      step += 1
      last_loss = loss.item
      publish_point("reconstruction-loss", step, last_loss)
      progress.inc!
    if (epoch + 1) % 100 == 0 or epoch + 1 == epochs:
      print("Эпоха #{epoch + 1}/#{epochs} · шаг #{step} · MSE #{last_loss}")
  model.eval!
  final_loss = torch.no_grad:
    criterion(model(all_features), all_features).item
  progress.end
  seconds = (Time.monotonic - started).total_nanoseconds.float / 1e9
  parameter_count = model.parameters.reduce(0) |total, parameter|: total + parameter.numel
  {initial_loss:, final_loss:, seconds:, steps: step, parameters: parameter_count,
    count: samples.count, epochs:, device:}
