// Set by forkop.js when the session cannot load the Forkop UCI package, i.e.
// the LuCI role only has the read-only Forkop ACL group.
let readonlyMode = false;

export function setReadonlyMode(value: boolean) {
  readonlyMode = value;
}

export function isReadonlyMode() {
  return readonlyMode;
}
