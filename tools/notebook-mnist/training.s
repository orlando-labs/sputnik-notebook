package mnist_demo

import sputniktorch
from sputniktorch.nn import CrossEntropyLoss
from sputniktorch.optim import AdamW
from sputniktorch.optim.lr_scheduler import CosineAnnealingLR
from sputniktorch.data import DataLoader
from sputniktorch.mnist.dataset import MNIST
from sputniktorch.mnist.network import SmallResNet
from progressbar import ProgressBar
from plot import figure
from notebook.ui import publish_point, image, publish_images, clear_images

export train_mnist

def loss_figure(points):
  figure(width: 900, height: 420).title("Learning to recognize handwritten digits").axes(
    x_label: "Optimizer step", y_label: "Cross-entropy loss").line(
    points, stroke: "#d97706", stroke_width: 2, label: "Training loss")

def evaluate_model(model, batches, loss_fn, device:, collect_worst: false):
  model.eval!
  sputniktorch.no_grad:
    loss_sum = 0.0
    correct = 0
    seen = 0
    samples = []
    sample_loss = CrossEntropyLoss(reduction: :none)
    batches.each |(features, labels)|:
      features = features.to(device:)
      labels = labels.to(device:)
      logits = model(features)
      loss_sum += loss_fn(logits, labels).item * labels.numel
      correct += logits.argmax(dim: 1).eq(labels).sum().item
      if collect_worst:
        losses = sample_loss(logits, labels).to(device: "cpu").to_a
        predicted = logits.argmax(dim: 1)
        confidence = logits.softmax(dim: 1).gather(1, predicted.unsqueeze(1)).flatten.to(device: "cpu").to_a
        predictions = predicted.to(device: "cpu").to_a
        targets = labels.to(device: "cpu").to_a
        labels.numel.times |index|:
          # Negative loss sorts worst first; index resolves ties deterministically.
          samples.push!((-losses[index], seen + index, predictions[index], targets[index], confidence[index]))
      seen += labels.numel
    metrics = (loss_sum / seen, correct.float / seen, samples.sorted.take(10))
    metrics

def publish_worst_samples(dataset, samples):
  frames = samples.map |(negative_loss, index, predicted, target, confidence)|:
    features = dataset[index][0]
    pixels = ((features * 0.3081 + 0.1307) * 255.0 + 0.5).clamp(min: 0, max: 255).to(device: "cpu", dtype: "uint8").flatten.to_a
    loss = Math.round(-negative_loss * 10000) / 10000
    percent = Math.round(confidence * 1000) / 10
    image(pixels, width: 28, height: 28, format: :gray,
      caption: "Validation ##{index + 1} · true #{target} · predicted #{predicted} (#{percent}%) · loss #{loss}")
  publish_images("worst-validation", frames,
    caption: "Worst #{frames.count} validation samples · highest cross-entropy first · final model · held-out MNIST test split")

# Same SmallResNet, normalization, seed and AdamW schedule as sputniktorch's
# examples/showcase.s. Only notebook presentation lives in this module.
def train_mnist(directory, device: "mps", epochs: 5, batch_size: 128,
    seed: 7, train_limit: null, test_limit: null, plot_throttle_ms: 500, visualization: :board):
  raise ValueError("epochs and batch_size must be positive") if epochs <= 0 or batch_size <= 0
  raise ValueError("MPS unavailable; select CPU explicitly") if device == "mps" and not sputniktorch.mps_available?
  raise ValueError("visualization must be :board, :plot or :none") unless [:board, :plot, :none].contains?(visualization)
  train = MNIST(directory, split: :train, limit: train_limit)
  test = MNIST(directory, split: :test, limit: test_limit)
  batches = DataLoader(train, batch_size:, shuffle: true, seed:)
  validation = DataLoader(test, batch_size:)
  model = SmallResNet(seed:, device:)
  loss_fn = CrossEntropyLoss()
  optimizer = AdamW(model.parameters, lr: 0.003, weight_decay: 0.0001)
  schedule = CosineAnnealingLR(optimizer, epochs, eta_min: 0.0003)
  parameters = model.parameters.reduce(0): _1 + _2.numel
  print("MNIST | #{device} | train #{train.count} | test #{test.count} | parameters #{parameters}")
  progress = null
  unless visualization == :none:
    progress = ProgressBar(total: epochs * batches.count, desc: "MNIST · optimizer steps", throttle: 0.1, id: "mnist-training")
  points = []
  validation_points = []
  step = 0
  last_accuracy = 0.0
  last_loss = 0.0
  worst_samples = []
  clear_images("worst-validation") unless visualization == :none
  started = Time.monotonic
  epochs.times |epoch|:
    model.train!(enabled: true)
    batches.sampler.set_epoch!(epoch)
    epoch_loss = 0.0
    seen = 0
    batches.each |(features, labels)|:
      features = features.to(device:)
      labels = labels.to(device:)
      optimizer.zero_grad!
      loss = loss_fn(model.call!(features), labels)
      loss.backward!()
      optimizer.step!
      value = loss.item
      epoch_loss += value * labels.numel
      seen += labels.numel
      step += 1
      if visualization == :board:
        publish_point("loss", step, value)
      elif visualization == :plot:
        points.push!([step, value])
        notebook.show(loss_figure(points), id: "loss", live: true,
          caption: "Training cross-entropy · every optimizer step", order: 0, throttle_ms: plot_throttle_ms)
      progress.inc! if progress != null
    evaluation = evaluate_model(model, validation, loss_fn, device:,
      collect_worst: visualization != :none and epoch + 1 == epochs)
    last_loss = evaluation[0]
    last_accuracy = evaluation[1]
    worst_samples = evaluation[2]
    validation_points.push!([epoch + 1, last_accuracy * 100])
    if visualization == :board:
      publish_point("accuracy", epoch + 1, last_accuracy * 100)
    elif visualization == :plot:
      accuracy_plot = figure(width: 900, height: 420).title("Held-out test accuracy").axes(
        x_label: "Epoch", y_label: "Accuracy (%)").domain(0, 0, epochs, 100).line(
        validation_points, stroke: "#059669", stroke_width: 3, label: "Test accuracy")
      notebook.show(accuracy_plot, id: "accuracy", live: true,
        caption: "Held-out MNIST test set · no training on test data", order: 1)
    print("Epoch #{epoch + 1}/#{epochs} | train loss #{epoch_loss / seen} | test loss #{last_loss} | accuracy #{last_accuracy * 100}%")
    schedule.step!
  if visualization == :plot:
    notebook.show(loss_figure(points), id: "loss", live: true,
      caption: "Training cross-entropy · #{step} optimizer steps", order: 0, throttle_ms: 0)
  publish_worst_samples(test, worst_samples) unless visualization == :none
  progress.end if progress != null
  elapsed = (Time.monotonic - started).total_nanoseconds.float / 1e9
  {accuracy: last_accuracy * 100, test_loss: last_loss, seconds: elapsed,
   steps: step, parameters:, train_count: train.count, test_count: test.count,
   device:, epochs:, worst_count: worst_samples.count}
