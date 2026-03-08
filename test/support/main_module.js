// Main module that imports other files
import { add, multiply } from "./math_utils.js";

globalThis.addNumbers = add;
globalThis.multiplyNumbers = multiply;
globalThis.appName = "TyrexTestApp";
