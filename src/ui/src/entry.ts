import { mount } from "svelte";
import App from "./routes/+page.svelte";

const target = document.getElementById("app");
if (target) {
  mount(App, { target });
}
