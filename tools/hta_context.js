// Loads the HTA's <script> into a Node VM with a minimal DOM (no ActiveX, so the HTA stays in
// preview mode). Shared by the maintenance tools so they read commands and templates from the
// HTA itself instead of keeping their own copies.
"use strict";
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const HTA_PATH = path.join(__dirname, "..", "fujikyun_rpa_builder.hta");

function htaScript() {
    const hta = fs.readFileSync(HTA_PATH, "utf8").replace(/^﻿/, "");
    return hta.match(/<script type="text\/javascript">([\s\S]*)<\/script>/)[1];
}

function el() {
    return { style: {}, className: "", innerHTML: "", value: "", options: { length: 0, add() {} }, children: [], childNodes: [],
        appendChild() {}, removeChild() {}, getElementsByTagName() { return []; }, setAttribute() {}, getAttribute() { return null; } };
}

// Returns R(code): evaluates code inside the HTA's global scope
function loadHta(script) {
    const els = {};
    const ctx = { window: {}, location: { href: "" }, screen: {}, setTimeout, clearTimeout,
        document: { getElementById: id => (els[id] = els[id] || el()), createElement: el, createTextNode: () => ({}), title: "t" } };
    vm.createContext(ctx);
    vm.runInContext(script || htaScript(), ctx);
    return code => vm.runInContext(code, ctx);
}

module.exports = { HTA_PATH, htaScript, loadHta };
