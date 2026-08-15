import {randomUUID} from "node:crypto";

import {op_apply} from "ext:core/ops";

globalThis.Tyrex = {
  _applications: {},
  _handleApplicationResult: (applicationId, result) => {
    Tyrex._applications[applicationId].resolve(result);
    delete Tyrex._applications[applicationId];
  },
  _applyReply: (applicationId, kind, value) => {
    const entry = Tyrex._applications[applicationId];
    if (!entry) {
      return;
    }
    delete Tyrex._applications[applicationId];
    const parsed = JSON.parse(value);
    if (kind === "resolve") {
      entry.resolve(parsed);
    } else {
      entry.reject(parsed);
    }
  },
  apply: (module, functionName, args) => {
    if (typeof module !== "string") {
      throw new Error(`Not a string: ${module}`);
    }
    if (typeof functionName !== "string") {
      throw new Error(`Not a string: ${functionName}`);
    }
    if (!Array.isArray(args)) {
      throw new Error(`Not an array: ${args}`);
    }
    const applicationId = randomUUID();
    const promise = new Promise((resolve, reject) => {
      Tyrex._applications[applicationId] = {reject, resolve};
    });
    op_apply(applicationId, module, functionName, JSON.stringify(args));
    return promise;
  },
};
