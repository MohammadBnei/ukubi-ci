import { expect, test } from "bun:test";
import { greet } from "./index";

test("greet", () => {
  expect(greet("ci")).toBe("hello, ci");
});
