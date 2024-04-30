var start_pos = null;
var end_pos = null;

function render() {
  const image = document.getElementById("image_source");
  const canvas = document.getElementById("input_image_canvas");
  canvas.width = image.width;
  canvas.height = image.height;

  const ctx = canvas.getContext("2d");
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  ctx.drawImage(image, 0, 0);

  if (start_pos !== null && end_pos !== null) {
    ctx.strokeStyle = "red";
    ctx.rect(
      start_pos[0],
      start_pos[1],
      end_pos[0] - start_pos[0],
      end_pos[1] - start_pos[1],
    );
    ctx.stroke();
  }
}

async function renderBinarizedHistogram(data) {
  const canvas = document.getElementById("binarized_histogram");
  const ctx = canvas.getContext("2d");

  const split_point_response = await fetch("/dark_light_partition");
  const split_point = await split_point_response.json();

  const max_val = Math.max.apply(null, data);
  const bar_width = canvas.width / 256;

  ctx.fillStyle = "white";
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  for (let i = 0; i < 256; ++i) {
    const x = i * bar_width;
    const width = bar_width;
    ctx.fillStyle = "blue";
    if (i > split_point) {
      ctx.fillStyle = "yellow";
    }
    ctx.fillRect(x, canvas.height, width, (-canvas.height * data[i]) / max_val);
  }
}

async function renderClusteredHistogram(data) {
  const canvas = document.getElementById("cluster_histogram");
  const ctx = canvas.getContext("2d");

  const clusters_response = await fetch("/clusters");
  const clusters_data = await clusters_response.json();

  const max_val = Math.max.apply(null, data);
  const bar_width = canvas.width / 256;

  ctx.fillStyle = "white";
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  for (let i = 0; i < clusters_data.length; ++i) {
    const cluster = clusters_data[i];
    const colors = ["red", "green", "yellow", "orange"];
    for (let j = cluster[0]; j <= cluster[1]; ++j) {
      const x = j * bar_width;
      const width = bar_width;
      ctx.fillStyle = colors[i % colors.length];
      ctx.fillRect(
        x,
        canvas.height,
        width,
        (-canvas.height * data[j]) / max_val,
      );
    }
  }
}

async function renderHistograms() {
  const binarized = document.getElementById("image_binarized");
  binarized.src = "/binarized_image?timestamp=" + Date.now();

  const response = await fetch("/histogram");
  const data = await response.json();

  await renderBinarizedHistogram(data);
  await renderClusteredHistogram(data);
}

async function updateRoi() {
  await fetch(
    "/set_roi?start_x=" +
      start_pos[0] +
      "&start_y=" +
      start_pos[1] +
      "&end_x=" +
      end_pos[0] +
      "&end_y=" +
      end_pos[1],
  );
  const output = document.getElementById("image_output");
  // Force image refresh
  output.src = "/image_output?timestamp=" + Date.now();
  renderHistograms();
}

async function updateSmoothingRadius() {
  const smoothing_val = document.getElementById("smoothing_range").value;
  const smoothing_iterations = document.getElementById(
    "smoothing_iterations",
  ).value;
  await fetch(
    "/set_hist_smoothing?smoothing_radius=" +
      smoothing_val +
      "&smoothing_iterations=" +
      smoothing_iterations,
  );
  renderHistograms();
}

function init() {
  const canvas = document.getElementById("input_image_canvas");
  canvas.onmousedown = (e) => {
    start_pos = [e.offsetX, e.offsetY];
  };

  canvas.onmousemove = (e) => {
    if (e.buttons == 1) {
      end_pos = [e.offsetX, e.offsetY];
      render();
    }
  };

  canvas.onmouseup = () => {
    updateRoi();
  };

  document.getElementById("smoothing_range").onchange = updateSmoothingRadius;
  document.getElementById("smoothing_iterations").onchange =
    updateSmoothingRadius;

  render();
  updateSmoothingRadius();
}

window.onload = init;
