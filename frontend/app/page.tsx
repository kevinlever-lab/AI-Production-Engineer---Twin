import Twin from '@/components/twin';

/**
 * Home
 *
 * Landing page for the "AI in Production" course project, hosting the
 * Digital Twin chat interface. Renders a page header/subtitle, embeds the
 * `<Twin>` chat component within a fixed-height container, and shows a
 * small course-context footer.
 *
 * Layout:
 * - Full-height gradient background with a centered, max-width content
 *   column.
 * - Title ("AI in Production") and subtitle explaining the page's
 *   purpose.
 * - A fixed 600px-tall container housing the `<Twin>` chat widget, which
 *   handles all conversation state and communication with the backend
 *   itself.
 * - A footer labeling this as the "Week 2: Building Your Digital Twin"
 *   course milestone.
 *
 * Note: This page is purely a layout/container — all chat logic (sending
 * messages, displaying responses, session handling) lives inside the
 * `Twin` component.
 */

export default function Home() {
  return (
    <main className="min-h-screen bg-gradient-to-br from-slate-50 to-gray-100">
      <div className="container mx-auto px-4 py-8">
        <div className="max-w-4xl mx-auto">
          <h1 className="text-4xl font-bold text-center text-gray-800 mb-2">
            AI in Production
          </h1>
          <p className="text-center text-gray-600 mb-8">
            Deploy your Digital Twin to the cloud
          </p>

          <div className="h-[600px]">
            <Twin />
          </div>

          <footer className="mt-8 text-center text-sm text-gray-500">
            <p>Week 2: Building Your Digital Twin</p>
          </footer>
        </div>
      </div>
    </main>
  );
}