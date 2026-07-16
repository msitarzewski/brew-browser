<script lang="ts">
  /**
   * ReadinessPill — capability verdict badge shared by bundle cards and the
   * bundle detail. Maps the M1 `readiness()` verdict to a tone + label; the
   * `reason` (tier note or blocking reason) is the hover tooltip. Never a hard
   * block — "Not recommended" still allows install behind a confirm (M3).
   */
  import Pill from "./Pill.svelte";
  import { formatReadinessLabel, formatReadinessReason } from "$lib/i18n/messages";
  import { ui } from "$lib/stores/ui.svelte";
  import type { ReadinessVerdict } from "$lib/types";

  interface Props {
    verdict: ReadinessVerdict;
    reason: string;
  }
  let { verdict, reason }: Props = $props();

  const TONE = { ready: "success", marginal: "warning", blocked: "danger" } as const;
  const label = $derived(formatReadinessLabel(verdict, ui.locale));
  const title = $derived(formatReadinessReason(reason, ui.locale));
</script>

<span title={title}>
  <Pill tone={TONE[verdict]}>{label}</Pill>
</span>
