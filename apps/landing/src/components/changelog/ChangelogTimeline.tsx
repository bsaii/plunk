import {motion} from 'framer-motion';
import {ArrowRight, ArrowUpRight} from 'lucide-react';
import Link from 'next/link';
import React from 'react';

import type {ChangelogEntry} from '../../content/changelog';
import {formatDay, groupByMonth} from '../../content/changelog';
import {Label} from '../Mono';
import {ChangelogArtifactView} from './artifacts';

type MajorEntry = Extract<ChangelogEntry, {kind: 'major'}>;
type MinorEntry = Extract<ChangelogEntry, {kind: 'minor'}>;

const EASE = [0.23, 1, 0.32, 1] as const;

const reveal = {
  initial: {opacity: 0, y: 12},
  whileInView: {opacity: 1, y: 0},
  viewport: {once: true, margin: '-10%'},
  transition: {duration: 0.6, ease: EASE},
} as const;

function ReadMore({href, title}: {href: string; title: string}) {
  const external = href.startsWith('http');
  // Up-right means "leaves the site", as everywhere else on the landing site.
  const Arrow = external ? ArrowUpRight : ArrowRight;
  return (
    <Link
      href={href}
      {...(external ? {target: '_blank', rel: 'noopener noreferrer'} : {})}
      className={
        'group mt-4 inline-flex items-center gap-1 text-ui font-semibold text-neutral-900 underline decoration-neutral-300 underline-offset-4 transition hover:decoration-neutral-900'
      }
    >
      {external ? 'Read the docs' : 'Explore the feature'}
      <span className={'sr-only'}>: {title}</span>
      <Arrow
        className={`h-3.5 w-3.5 transition-transform ${external ? 'group-hover:-translate-y-px group-hover:translate-x-px' : 'group-hover:translate-x-0.5'}`}
        strokeWidth={2}
      />
    </Link>
  );
}

/**
 * A headline feature: copy on the left, a miniature of the product on the
 * right. The square node on the rail is filled, so the eye can run down the
 * line and pick out the big releases without reading anything.
 */
function Major({entry}: {entry: MajorEntry}) {
  return (
    <motion.article {...reveal} className={'relative grid items-start gap-8 md:grid-cols-2 xl:gap-12'}>
      <span
        aria-hidden
        className={'absolute -left-8 top-[0.2rem] h-2.5 w-2.5 -translate-x-[calc(50%-0.5px)] rounded-[3px] bg-neutral-900 sm:-left-12 md:top-[0.45rem]'}
      />
      <div className={'md:pt-1'}>
        <Label as={'p'}>
          <time dateTime={entry.date}>{formatDay(entry.date)}</time>
        </Label>
        <h3 className={'mt-2 font-display text-lead font-bold tracking-[-0.015em] text-neutral-900'}>{entry.title}</h3>
        <p className={'mt-2 max-w-[48ch] text-neutral-600'}>{entry.description}</p>
        {entry.href && <ReadMore href={entry.href} title={entry.title} />}
      </div>
      <div className={'min-w-0'}>
        <ChangelogArtifactView artifact={entry.artifact} />
      </div>
    </motion.article>
  );
}

/**
 * A smaller improvement. The tag is its picture: the literal header, endpoint
 * or operator a developer would recognise before reading the sentence.
 */
function Minor({entry, index}: {entry: MinorEntry; index: number}) {
  return (
    <motion.article
      {...reveal}
      transition={{...reveal.transition, delay: (index % 2) * 0.06}}
      className={'min-w-0'}
    >
      {/* Metadata on top, as on a headline entry: the tag and the date share a
          row, then the title and sentence read as one block. */}
      <div className={'flex min-w-0 items-center gap-3'}>
        <span
          className={
            'inline-block min-w-0 truncate rounded-md border border-neutral-200 bg-neutral-50 px-2 py-1 font-code text-[0.75rem] text-neutral-800'
          }
        >
          {entry.tag}
        </span>
        <Label as={'p'} className={'flex-shrink-0'}>
          <time dateTime={entry.date}>{formatDay(entry.date)}</time>
        </Label>
      </div>
      <h3 className={'mt-3 font-display text-body font-semibold text-neutral-900'}>
        {entry.href ? (
          <Link
            href={entry.href}
            {...(entry.href.startsWith('http') ? {target: '_blank', rel: 'noopener noreferrer'} : {})}
            className={'underline decoration-neutral-300 underline-offset-4 transition hover:decoration-neutral-900'}
          >
            {entry.title}
          </Link>
        ) : (
          entry.title
        )}
      </h3>
      <p className={'mt-1 text-neutral-600'}>{entry.description}</p>
    </motion.article>
  );
}

/**
 * The timeline, one band per month.
 *
 * Each month's heading is sticky inside its own grid row, so while you scroll
 * through a month its name stays pinned beside it and hands over to the next
 * month at the boundary. That gives the "where am I" of a scroll-spy rail with
 * no observer and no JavaScript.
 *
 * Within a month the headline features come first and the smaller changes sit
 * together underneath in two columns. Strict date order would scatter single
 * small items between large artifacts and bury the release the month is
 * actually about.
 */
export function ChangelogTimeline({entries}: {entries: ChangelogEntry[]}) {
  const months = groupByMonth(entries);

  return (
    <div className={'mx-auto max-w-[88rem] px-6 sm:px-10'}>
      {months.map(month => {
        const majors = month.entries.filter((e): e is MajorEntry => e.kind === 'major');
        const minors = month.entries.filter((e): e is MinorEntry => e.kind === 'minor');

        return (
          <section
            key={month.key}
            id={month.key}
            aria-labelledby={`${month.key}-title`}
            className={'grid scroll-mt-24 gap-x-8 gap-y-8 border-t border-neutral-200 py-14 sm:py-20 lg:grid-cols-12 xl:gap-x-16'}
          >
            <div className={'lg:col-span-3'}>
              <div className={'lg:sticky lg:top-28'}>
                <h2
                  id={`${month.key}-title`}
                  className={'font-display text-h3 font-extrabold tracking-[-0.025em] text-neutral-900'}
                >
                  {month.label}
                </h2>
                <Label as={'p'} className={'mt-1'}>
                  {month.entries.length} {month.entries.length === 1 ? 'update' : 'updates'}
                </Label>
              </div>
            </div>

            <div className={'relative min-w-0 pl-8 sm:pl-12 lg:col-span-9'}>
              <span aria-hidden className={'absolute bottom-0 left-0 top-2 w-px bg-neutral-200'} />

              <div className={'flex flex-col gap-16'}>
                {majors.map(entry => (
                  <Major key={`${entry.date}-${entry.title}`} entry={entry} />
                ))}

                {minors.length > 0 && (
                  <div className={'relative'}>
                    <span
                      aria-hidden
                      className={
                        'absolute -left-8 top-[0.55rem] h-2.5 w-2.5 -translate-x-[calc(50%-0.5px)] rounded-[3px] border border-neutral-400 bg-white sm:-left-12'
                      }
                    />
                    <div className={'grid gap-x-12 gap-y-10 sm:grid-cols-2'}>
                      {minors.map((entry, i) => (
                        <Minor key={`${entry.date}-${entry.title}`} entry={entry} index={i} />
                      ))}
                    </div>
                  </div>
                )}
              </div>
            </div>
          </section>
        );
      })}
    </div>
  );
}
