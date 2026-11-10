'use strict';

const preview = document.querySelector('#preview');
const status = document.querySelector('#status');
const picker = document.querySelector('#camera-picker');
const camera = document.querySelector('#camera');
const retry = document.querySelector('#retry');
const canvas = document.createElement('canvas');
const pixels = canvas.getContext('2d', {willReadFrequently: true});
let stream;
let timer;
let heartbeat;
let closed = false;
let opening = false;

function stopCamera() {
  clearTimeout(timer);
  stream?.getTracks().forEach(track => track.stop());
  stream = undefined;
  preview.srcObject = null;
}

function finish(message) {
  closed = true;
  clearInterval(heartbeat);
  stopCamera();
  picker.hidden = true;
  retry.hidden = true;
  status.textContent = message;
}

function sessionEnded() {
  finish('This scan session has ended. Return to ShadowNetwork Admin.');
}

async function scan(activeStream) {
  if (closed || stream !== activeStream) return;
  if (preview.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA) {
    const width = preview.videoWidth;
    const height = preview.videoHeight;
    if (width > 0 && height > 0) {
      if (canvas.width !== width) canvas.width = width;
      if (canvas.height !== height) canvas.height = height;
      pixels.drawImage(preview, 0, 0, width, height);
      const frame = pixels.getImageData(0, 0, width, height);
      const code = jsQR(frame.data, width, height, {inversionAttempts: 'dontInvert'});
      if (code && await submitCode(code.data)) return;
    }
  }
  if (!closed && stream === activeStream) {
    timer = setTimeout(() => scan(activeStream), 180);
  }
}

let lastRejected;
async function submitCode(source) {
  if (source === lastRejected) return false;
  try {
    const response = await fetch('result', {method: 'POST', body: source});
    if (response.status === 204) {
      finish('Registration read. Return to ShadowNetwork Admin to review the details.');
      window.close();
      return true;
    }
    if (response.status === 422 || response.status === 413) {
      lastRejected = source;
      status.textContent = 'Show a valid registration QR from the ShadowNetwork phone app.';
      return false;
    }
  } catch (_) {
    if (closed) return true;
  }
  sessionEnded();
  return true;
}

async function openCamera(deviceId) {
  if (closed || opening) return;
  opening = true;
  stopCamera();
  retry.hidden = true;
  camera.disabled = true;
  status.textContent = 'Opening camera…';
  try {
    const opened = await navigator.mediaDevices.getUserMedia({
      audio: false,
      video: {
        width: {ideal: 1280}, height: {ideal: 720},
        ...(deviceId ? {deviceId: {exact: deviceId}} : {}),
      },
    });
    if (closed) {
      opened.getTracks().forEach(track => track.stop());
      return;
    }
    stream = opened;
    preview.srcObject = stream;
    await preview.play();
    const devices = await navigator.mediaDevices.enumerateDevices();
    if (closed) return;
    const inputs = devices.filter(device => device.kind === 'videoinput');
    camera.replaceChildren(...inputs.map((device, index) =>
      new Option(device.label || `Camera ${index + 1}`, device.deviceId)));
    camera.value = opened.getVideoTracks()[0].getSettings().deviceId || '';
    picker.hidden = inputs.length < 2;
    status.textContent = 'Looking for a registration QR…';
    void scan(opened);
  } catch (error) {
    if (closed) return;
    stopCamera();
    status.textContent = error.name === 'NotAllowedError'
      ? 'Camera access is blocked. Allow it in your browser and retry.'
      : 'Could not open the camera. Close other apps using it and retry.';
    retry.hidden = false;
  } finally {
    opening = false;
    camera.disabled = false;
  }
}

camera.addEventListener('change', () => openCamera(camera.value));
retry.addEventListener('click', () => openCamera(camera.value));
window.addEventListener('pagehide', () => finish('Scanner closed.'));
heartbeat = setInterval(async () => {
  try {
    const response = await fetch('status', {cache: 'no-store'});
    if (!closed && !response.ok) sessionEnded();
  } catch (_) {
    if (!closed) sessionEnded();
  }
}, 2000);
void openCamera();
