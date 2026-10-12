"use strict";
const { contextBridge, ipcRenderer } = require("electron");
const methods = [
  "state",
  "paste",
  "settings",
  "choose-folder",
  "folder-list",
  "folder-create",
  "import-text",
  "login",
  "login-close",
  "article-capture",
  "task",
  "cancel",
  "photo-save",
  "photo-cancel",
  "photo-copy",
  "collection-create",
  "collection-notes",
  "collection-move",
  "collection-reorder",
  "enqueue",
  "queue-start",
  "queue-stop",
  "queue-retry",
  "queue-audio-retry",
  "remove",
  "reveal",
  "open",
  "media",
  "thumbnail",
  "cover",
  "login-clear",
  "filter-posts",
  "card-content",
  "enqueue-posts",
];
contextBridge.exposeInMainWorld(
  "shiying",
  Object.freeze({
    call: (name, payload) =>
      methods.includes(name)
        ? ipcRenderer.invoke("shiying:" + name, payload)
        : Promise.reject(Error("未知操作")),
    on: (handler) => {
      const listener = (_event, payload) => handler(payload);
      ipcRenderer.on("shiying:event", listener);
      return () => ipcRenderer.removeListener("shiying:event", listener);
    },
  }),
);
