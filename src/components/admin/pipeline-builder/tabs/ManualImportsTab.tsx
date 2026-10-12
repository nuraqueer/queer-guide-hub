import { Tabs, TabsList, TabsTrigger, TabsContent } from '@/components/ui/tabs';
import { VenueProviderImport } from '@/components/admin/venues/VenueProviderImport';
import { VenuesCsvImport } from '@/components/venues/VenuesCsvImport';
import { TicketmasterImport } from '@/components/events/TicketmasterImport';
import { EventsCsvImport } from '@/components/events/EventsCsvImport';
import { PersonalitiesCsvImport } from '@/components/personalities/PersonalitiesCsvImport';
import { AdultModelsCsvImport } from '@/components/personalities/AdultModelsCsvImport';
import { BulkCreatePersonalities } from '@/components/personalities/BulkCreatePersonalities';
import { AwinImportDialog } from '@/components/marketplace/AwinImportDialog';
import { UrlImportCard } from '@/components/admin/UrlImportCard';

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="flex flex-col gap-4">
      <h3 className="text-title font-semibold">{title}</h3>
      <div>{children}</div>
    </section>
  );
}

export default function ManualImportsTab() {
  return (
    <div className="flex flex-col gap-6">
      <div>
        <h2 className="text-title font-semibold">Manual imports</h2>
        <p className="text-sm text-muted-foreground">
          Import from a URL, a file, or a provider. Check each tool’s result, then review new
          content in the inbox.
        </p>
      </div>

      <UrlImportCard />

      <Tabs defaultValue="venues">
        <TabsList className="max-w-full overflow-x-auto justify-start">
          <TabsTrigger value="venues">Venues</TabsTrigger>
          <TabsTrigger value="events">Events</TabsTrigger>
          <TabsTrigger value="personalities">Personalities</TabsTrigger>
          <TabsTrigger value="marketplace">Marketplace</TabsTrigger>
        </TabsList>

        <TabsContent value="venues" className="flex flex-col gap-6 pt-4">
          <Section title="Provider import">
            <VenueProviderImport />
          </Section>
          <Section title="CSV import">
            <VenuesCsvImport />
          </Section>
        </TabsContent>

        <TabsContent value="events" className="flex flex-col gap-6 pt-4">
          <p className="text-sm text-muted-foreground">
            Eventbrite search is unavailable because its API endpoint was retired. Use a URL or CSV
            instead.
          </p>
          <Section title="Ticketmaster">
            <TicketmasterImport />
          </Section>
          <Section title="CSV import">
            <EventsCsvImport />
          </Section>
        </TabsContent>

        <TabsContent value="personalities" className="flex flex-col gap-6 pt-4">
          <Section title="CSV import">
            <PersonalitiesCsvImport />
          </Section>
          <Section title="Adult models CSV">
            <AdultModelsCsvImport />
          </Section>
          <Section title="Bulk create">
            <BulkCreatePersonalities />
          </Section>
        </TabsContent>

        <TabsContent value="marketplace" className="flex flex-col gap-6 pt-4">
          <Section title="Awin product feed">
            <AwinImportDialog />
          </Section>
        </TabsContent>
      </Tabs>
    </div>
  );
}
