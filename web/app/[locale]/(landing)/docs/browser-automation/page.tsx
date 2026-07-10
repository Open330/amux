import { useTranslations } from "next-intl";
import { getTranslations } from "next-intl/server";
import { buildAlternates } from "@/i18n/seo";
import { DocsSchema } from "../docs-schema";
import { CodeBlock } from "@/app/[locale]/components/code-block";
import { DocsHeading } from "@/app/[locale]/components/docs-heading";

export async function generateMetadata({ params }: { params: Promise<{ locale: string }> }) {
  const { locale } = await params;
  const t = await getTranslations({ locale, namespace: "docs.browserAutomation" });
  return {
    title: t("metaTitle"),
    description: t("metaDescription"),
    alternates: buildAlternates(locale, "/docs/browser-automation"),
  };
}

export default function BrowserAutomationPage() {
  const t = useTranslations("docs.browserAutomation");

  return (
    <>
      <DocsSchema namespace="docs.browserAutomation" path="/docs/browser-automation" />
      <DocsHeading level={1} id="title">{t("title")}</DocsHeading>
      <p>{t("intro")}</p>

      <DocsHeading level={2} id="command-index">{t("commandIndex")}</DocsHeading>
      <table>
        <thead>
          <tr>
            <th>{t("categoryHeader")}</th>
            <th>{t("subcommandsHeader")}</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>{t("navAndTargeting")}</td>
            <td>
              <code>identify</code>, <code>open</code>, <code>open-split</code>,{" "}
              <code>navigate</code>, <code>back</code>, <code>forward</code>,{" "}
              <code>reload</code>, <code>url</code>, <code>focus-webview</code>,{" "}
              <code>is-webview-focused</code>, <code>zoom</code>,{" "}
              <code>focus-mode</code>, <code>react-grab</code>, <code>devtools</code>
            </td>
          </tr>
          <tr>
            <td>{t("waiting")}</td>
            <td>
              <code>wait</code>
            </td>
          </tr>
          <tr>
            <td>{t("domInteraction")}</td>
            <td>
              <code>click</code>, <code>dblclick</code>, <code>hover</code>,{" "}
              <code>focus</code>, <code>check</code>, <code>uncheck</code>,{" "}
              <code>scroll-into-view</code>, <code>type</code>, <code>fill</code>,{" "}
              <code>press</code>, <code>keydown</code>, <code>keyup</code>,{" "}
              <code>select</code>, <code>scroll</code>
            </td>
          </tr>
          <tr>
            <td>{t("inspection")}</td>
            <td>
              <code>snapshot</code>, <code>screenshot</code>, <code>get</code>,{" "}
              <code>is</code>, <code>find</code>, <code>highlight</code>
            </td>
          </tr>
          <tr>
            <td>{t("jsAndInjection")}</td>
            <td>
              <code>eval</code>, <code>addinitscript</code>, <code>addscript</code>,{" "}
              <code>addstyle</code>
            </td>
          </tr>
          <tr>
            <td>{t("framesDialogsDownloads")}</td>
            <td>
              <code>frame</code>, <code>dialog</code>, <code>download</code>
            </td>
          </tr>
          <tr>
            <td>{t("stateAndSession")}</td>
            <td>
              <code>cookies</code>, <code>storage</code>, <code>state</code>,{" "}
              <code>history</code>
            </td>
          </tr>
          <tr>
            <td>{t("tabsAndLogs")}</td>
            <td>
              <code>tab</code>, <code>console</code>, <code>errors</code>
            </td>
          </tr>
        </tbody>
      </table>

      <DocsHeading level={2} id="targeting-surface">{t("targetingSurface")}</DocsHeading>
      <p>{t("targetingDesc")}</p>
      <CodeBlock lang="bash">{`# Open a new browser split
amux browser open https://example.com

# Discover focused IDs and browser metadata
amux browser identify
amux browser identify --surface surface:2

# Positional vs flag targeting are equivalent
amux browser surface:2 url
amux browser --surface surface:2 url`}</CodeBlock>

      <DocsHeading level={2} id="navigation">{t("navigation")}</DocsHeading>
      <CodeBlock lang="bash">{`amux browser open https://example.com
amux browser open-split https://news.ycombinator.com

amux browser surface:2 navigate https://example.org/docs --snapshot-after
amux browser surface:2 back
amux browser surface:2 forward
amux browser surface:2 reload --snapshot-after
amux browser surface:2 url

amux browser surface:2 focus-webview
amux browser surface:2 is-webview-focused

amux browser react-grab toggle
amux browser devtools toggle
amux browser devtools console
amux browser focus-mode toggle
amux browser zoom in
amux browser zoom reset
amux browser history clear --force`}</CodeBlock>

      <DocsHeading level={2} id="waiting-section">{t("waitingSection")}</DocsHeading>
      <p>{t("waitingDesc")}</p>
      <CodeBlock lang="bash">{`amux browser surface:2 wait --load-state complete --timeout-ms 15000
amux browser surface:2 wait --selector "#checkout" --timeout-ms 10000
amux browser surface:2 wait --text "Order confirmed"
amux browser surface:2 wait --url-contains "/dashboard"
amux browser surface:2 wait --function "window.__appReady === true"`}</CodeBlock>

      <DocsHeading level={2} id="dom-section">{t("domSection")}</DocsHeading>
      <p>{t("domDesc")}</p>
      <CodeBlock lang="bash">{`amux browser surface:2 click "button[type='submit']" --snapshot-after
amux browser surface:2 dblclick ".item-row"
amux browser surface:2 hover "#menu"
amux browser surface:2 focus "#email"
amux browser surface:2 check "#terms"
amux browser surface:2 uncheck "#newsletter"
amux browser surface:2 scroll-into-view "#pricing"

amux browser surface:2 type "#search" "amux"
amux browser surface:2 fill "#email" --text "ops@example.com"
amux browser surface:2 fill "#email" --text ""
amux browser surface:2 press Enter
amux browser surface:2 keydown Shift
amux browser surface:2 keyup Shift
amux browser surface:2 select "#region" "us-east"
amux browser surface:2 scroll --dy 800 --snapshot-after
amux browser surface:2 scroll --selector "#log-view" --dx 0 --dy 400`}</CodeBlock>

      <DocsHeading level={2} id="inspection-section">{t("inspectionSection")}</DocsHeading>
      <p>{t("inspectionDesc")}</p>
      <CodeBlock lang="bash">{`amux browser surface:2 snapshot --interactive --compact
amux browser surface:2 snapshot --selector "main" --max-depth 5
amux browser surface:2 screenshot --out /tmp/cmux-page.png

amux browser surface:2 get title
amux browser surface:2 get url
amux browser surface:2 get text "h1"
amux browser surface:2 get html "main"
amux browser surface:2 get value "#email"
amux browser surface:2 get attr "a.primary" --attr href
amux browser surface:2 get count ".row"
amux browser surface:2 get box "#checkout"
amux browser surface:2 get styles "#total" --property color

amux browser surface:2 is visible "#checkout"
amux browser surface:2 is enabled "button[type='submit']"
amux browser surface:2 is checked "#terms"

amux browser surface:2 find role button --name "Continue"
amux browser surface:2 find text "Order confirmed"
amux browser surface:2 find label "Email"
amux browser surface:2 find placeholder "Search"
amux browser surface:2 find alt "Product image"
amux browser surface:2 find title "Open settings"
amux browser surface:2 find testid "save-btn"
amux browser surface:2 find first ".row"
amux browser surface:2 find last ".row"
amux browser surface:2 find nth 2 ".row"

amux browser surface:2 highlight "#checkout"`}</CodeBlock>

      <DocsHeading level={2} id="js-section">{t("jsSection")}</DocsHeading>
      <CodeBlock lang="bash">{`amux browser surface:2 eval "document.title"
amux browser surface:2 eval --script "window.location.href"

amux browser surface:2 addinitscript "window.__cmuxReady = true;"
amux browser surface:2 addscript "document.querySelector('#name')?.focus()"
amux browser surface:2 addstyle "#debug-banner { display: none !important; }"`}</CodeBlock>

      <DocsHeading level={2} id="state-section">{t("stateSection")}</DocsHeading>
      <p>{t("stateDesc")}</p>
      <CodeBlock lang="bash">{`amux browser surface:2 cookies get
amux browser surface:2 cookies get --name session_id
amux browser surface:2 cookies set session_id abc123 --domain example.com --path /
amux browser surface:2 cookies clear --name session_id
amux browser surface:2 cookies clear --all

amux browser surface:2 storage local set theme dark
amux browser surface:2 storage local get theme
amux browser surface:2 storage local clear
amux browser surface:2 storage session set flow onboarding
amux browser surface:2 storage session get flow

amux browser surface:2 state save /tmp/cmux-browser-state.json
amux browser surface:2 state load /tmp/cmux-browser-state.json`}</CodeBlock>

      <DocsHeading level={2} id="tabs-section">{t("tabsSection")}</DocsHeading>
      <p>{t("tabsDesc")}</p>
      <CodeBlock lang="bash">{`amux browser surface:2 tab list
amux browser surface:2 tab new https://example.com/pricing

# Switch by index or by target surface
amux browser surface:2 tab switch 1
amux browser surface:2 tab switch surface:7

# Close current tab or a specific target
amux browser surface:2 tab close
amux browser surface:2 tab close surface:7`}</CodeBlock>

      <DocsHeading level={2} id="console-section">{t("consoleSection")}</DocsHeading>
      <CodeBlock lang="bash">{`amux browser surface:2 console list
amux browser surface:2 console clear

amux browser surface:2 errors list
amux browser surface:2 errors clear`}</CodeBlock>

      <DocsHeading level={2} id="dialogs-section">{t("dialogsSection")}</DocsHeading>
      <CodeBlock lang="bash">{`amux browser surface:2 dialog accept
amux browser surface:2 dialog accept "Confirmed by automation"
amux browser surface:2 dialog dismiss`}</CodeBlock>

      <DocsHeading level={2} id="frames-section">{t("framesSection")}</DocsHeading>
      <CodeBlock lang="bash">{`# Enter an iframe context
amux browser surface:2 frame "iframe[name='checkout']"
amux browser surface:2 click "#pay-now"

# Return to the top-level document
amux browser surface:2 frame main`}</CodeBlock>

      <DocsHeading level={2} id="downloads-section">{t("downloadsSection")}</DocsHeading>
      <CodeBlock lang="bash">{`amux browser surface:2 click "a#download-report"
amux browser surface:2 download --path /tmp/report.csv --timeout-ms 30000`}</CodeBlock>

      <DocsHeading level={2} id="common-patterns">{t("commonPatterns")}</DocsHeading>

      <DocsHeading level={3} id="pattern-navigate">{t("patternNavigate")}</DocsHeading>
      <CodeBlock lang="bash">{`amux browser open https://example.com/login
amux browser surface:2 wait --load-state complete --timeout-ms 15000
amux browser surface:2 snapshot --interactive --compact
amux browser surface:2 get title`}</CodeBlock>

      <DocsHeading level={3} id="pattern-form">{t("patternForm")}</DocsHeading>
      <CodeBlock lang="bash">{`amux browser surface:2 fill "#email" --text "ops@example.com"
amux browser surface:2 fill "#password" --text "$PASSWORD"
amux browser surface:2 click "button[type='submit']" --snapshot-after
amux browser surface:2 wait --text "Welcome"
amux browser surface:2 is visible "#dashboard"`}</CodeBlock>

      <DocsHeading level={3} id="pattern-debug">{t("patternDebug")}</DocsHeading>
      <CodeBlock lang="bash">{`amux browser surface:2 console list
amux browser surface:2 errors list
amux browser surface:2 screenshot --out /tmp/cmux-failure.png
amux browser surface:2 snapshot --interactive --compact`}</CodeBlock>

      <DocsHeading level={3} id="pattern-session">{t("patternSession")}</DocsHeading>
      <CodeBlock lang="bash">{`amux browser surface:2 state save /tmp/session.json
# ...later...
amux browser surface:2 state load /tmp/session.json
amux browser surface:2 reload`}</CodeBlock>
    </>
  );
}
