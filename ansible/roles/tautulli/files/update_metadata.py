#!/usr/bin/env python
# -*- coding: utf-8 -*-

'''
Description:  Selects the default TMDB poster, art and logo for items in a Plex library
              if none is selected or the current one is from Gracenote.
              The selected poster is the primary TMDB poster in the item's original language,
              and a season uses its own TMDB season poster in that language.
              The selected art is the primary TMDB backdrop.
              The selected logo is the primary TMDB logo in English for English media,
              otherwise in French with a fallback to the original language.
              Can also override the metadata language for non-English media and set
              the sort title without the leading article for French metadata.
              Seasons and episodes inherit their metadata from the show, so the logo,
              the metadata language and the sort title are applied to the parent show.
              Episodes have no artwork of their own, so their poster and art are
              curated on the parent season, and a show curates all of its seasons.
Author:       /u/SwiftPanda16 (original), shellt0pia (modifications)
Requires:     plexapi, requests
Environment:  PLEX_URL, PLEX_TOKEN, TAUTULLI_URL and TAUTULLI_APIKEY are provided by
              Tautulli when running as a notification script.
              TMDB API key read from the file at TMDB_API_KEY_FILE if set,
              otherwise from the TMDB_API_KEY environment variable
Usage:
    * Change the poster, the art and the logo of an item:
        python update_metadata.py --rating_key 1234 --poster --art --logo
    * By default locked fields are skipped. To update them:
        python update_metadata.py --rating_key 1234 --include_locked --poster --art
    * To override the provider used when TMDB has no image:
        python update_metadata.py --rating_key 1234 --art --art_provider "fanarttv"
    * Change the metadata language for non-English media and set the sort title
      without the leading article:
        python update_metadata.py --rating_key 1234 --language --sort_title
    * Send a recently added notification through another notifier once done
      (the notifier must not be this script):
        python update_metadata.py --rating_key 1234 --notify 2
    * Report metadata failures through another notifier:
        python update_metadata.py --rating_key 1234 --language --error_notify 3
Tautulli script trigger:
    * Notify on recently added
Tautulli script conditions:
    * Restrict the script to the media types it knows how to handle:
        [ Media Type | is | movie or show or season or episode ]
Tautulli script arguments:
    * Recently Added:
        --rating_key {rating_key} --poster --art --logo --language --sort_title
        --notify <notifier_id> --error_notify <admin_notifier_id>
'''

import argparse
import os
import sys
import time
import traceback
from collections import namedtuple
from contextlib import contextmanager
from urllib.parse import unquote
import requests
import plexapi.base
from plexapi.server import PlexServer
plexapi.base.USER_DONT_RELOAD_FOR_KEYS.add('fields')


# Poster and art providers to replace
REPLACE_PROVIDERS = ['gracenote', 'plex', None]

# Preferred poster and art provider to fall back on when TMDB has no image
# (Note not all providers are availble for all items)
# Possible options: tmdb, tvdb, imdb, fanarttv, gracenote, plex
PREFERRED_POSTER_PROVIDER = 'tmdb'
PREFERRED_ART_PROVIDER = 'tmdb'

# Original language for which the metadata language is left at the library default
DEFAULT_ORIGINAL_LANGUAGE = 'en'
# Metadata language to set for media with a different original language
METADATA_LANGUAGE_OVERRIDE = 'fr-FR'
# Logo language to prefer for media with a non-default original language (ISO 639-1)
LOGO_LANGUAGE_OVERRIDE = 'fr'

# Leading articles to strip from French titles to build the sort title
FRENCH_SORT_ARTICLES = ('le ', 'la ', 'les ', "l'", 'l\u2019', 'un ', 'une ', 'des ')

TMDB_API_URL = 'https://api.themoviedb.org/3'
TMDB_IMAGE_URL = 'https://image.tmdb.org/t/p/original'


def read_tmdb_api_key():
    key_file = os.getenv('TMDB_API_KEY_FILE')
    if key_file:
        with open(key_file) as f:
            return f.read().strip()
    return os.getenv('TMDB_API_KEY', '')


PLEX_URL = os.getenv('PLEX_URL', '')
PLEX_TOKEN = os.getenv('PLEX_TOKEN', '')
TMDB_API_KEY = read_tmdb_api_key()
TAUTULLI_URL = os.getenv('TAUTULLI_URL', '')
TAUTULLI_APIKEY = os.getenv('TAUTULLI_APIKEY', '')

TmdbInfo = namedtuple('TmdbInfo', 'original_language poster_path backdrop_path logo_path season_posters')
# Returned when TMDB cannot be queried, so callers never have to check for None
NO_TMDB_INFO = TmdbInfo(None, None, None, None, {})

MetadataTargets = namedtuple('MetadataTargets', 'matched_item artwork_items')

# The PlexAPI methods an item exposes for one kind of image
ImageKind = namedtuple('ImageKind', 'name field choices upload lock fallback_provider')


def tmdb_get(path, **params):
    '''Calls the TMDB API, returning the parsed payload or None when the call fails.'''
    try:
        response = requests.get(
            f"{TMDB_API_URL}/{path}",
            params={'api_key': TMDB_API_KEY, **params},
            timeout=30
        )
        response.raise_for_status()
        return response.json()
    except (requests.RequestException, ValueError) as e:
        print(f"  - WARNING: TMDB API request failed for '{path}': {e}")
        return None


def get_tmdb_info(item):
    '''Returns the original language, the primary poster path (in the original
    language), the primary backdrop path, the logo path and the per-season poster
    paths for an item, using the TMDB API.'''
    if not TMDB_API_KEY:
        print(f"  - WARNING: No TMDB API key configured. Skipping TMDB lookup for {full_title(item)}.")
        return NO_TMDB_INFO

    tmdb_id = next((guid.id.split('://')[1] for guid in item.guids if guid.id.startswith('tmdb://')), None)
    if tmdb_id is None:
        print(f"  - WARNING: No TMDB guid found for {full_title(item)}.")
        return NO_TMDB_INFO

    path = f"{'movie' if item.type == 'movie' else 'tv'}/{tmdb_id}"
    details = tmdb_get(path)
    if details is None:
        return NO_TMDB_INFO

    original_language = details.get('original_language')
    poster_path = details.get('poster_path')
    season_posters = extract_season_posters(details)

    if original_language:
        # The details endpoint with a language parameter returns the primary poster for that language
        localized = tmdb_get(path, language=original_language) or {}
        poster_path = localized.get('poster_path') or poster_path
        # Seasons without a localized poster keep the default one
        season_posters = {**season_posters, **extract_season_posters(localized)}

    # The backdrop from the base details is the TMDB primary background
    backdrop_path = details.get('backdrop_path')
    logo_path = get_tmdb_logo_path(path, original_language)

    return TmdbInfo(original_language, poster_path, backdrop_path, logo_path, season_posters)


def extract_season_posters(details):
    '''Maps season numbers to their TMDB poster path. The seasons array ships with the
    show details, so the season posters cost no extra request.'''
    return {season['season_number']: season['poster_path']
            for season in details.get('seasons') or []
            if season.get('poster_path') and season.get('season_number') is not None}


def get_tmdb_logo_path(path, original_language):
    '''Returns the primary TMDB logo path: English for English media, otherwise
    French with a fallback to the original language.'''
    if original_language is None:
        return None

    if original_language == DEFAULT_ORIGINAL_LANGUAGE:
        languages = [DEFAULT_ORIGINAL_LANGUAGE]
    else:
        languages = [LOGO_LANGUAGE_OVERRIDE, original_language]

    images = tmdb_get(f"{path}/images", include_image_language=','.join(languages)) or {}
    return find_logo_path(images.get('logos') or [], languages)


def find_logo_path(logos, languages):
    '''Logos are sorted by votes, so the first match is the primary one for that language.'''
    for language in languages:
        logo = next((entry for entry in logos if entry.get('iso_639_1') == language), None)
        if logo:
            return logo['file_path']
    return None


def resolve_targets(item):
    '''Metadata lives higher up the hierarchy than the item Tautulli notifies about:
    - matched_item: the movie or show the Plex agent matched, holding the TMDB guid,
      the metadata language, the sort title and the logo.
    - artwork_items: everything whose poster and background are curated. An episode
      thumb is a still frame, so its season is curated instead, and a whole newly added
      show is only notified once, which is the sole chance to curate its seasons.'''
    if item.type == 'episode':
        return MetadataTargets(matched_item=item.show(), artwork_items=[item.season()])
    if item.type == 'season':
        return MetadataTargets(matched_item=item.show(), artwork_items=[item])
    if item.type == 'show':
        return MetadataTargets(matched_item=item, artwork_items=[item] + item.seasons())
    return MetadataTargets(matched_item=item, artwork_items=[item])


def full_title(item):
    '''Plex titles are relative to the parent, so a season or an episode title on its
    own does not identify the media.'''
    if item.type == 'episode':
        return f"{item.grandparentTitle} - {item.seasonEpisode} - {item.title}"
    if item.type == 'season':
        return f"{item.parentTitle} - {item.title}"
    return item.title


def image_kind(item, name, opts):
    '''Binds the PlexAPI methods an item exposes for one kind of image. Logos have no
    fallback provider, TMDB is the only source Plex offers for them.'''
    kinds = {
        'poster': ImageKind('poster', 'thumb', item.posters, item.uploadPoster, item.lockPoster, opts.poster_provider),
        'art': ImageKind('art', 'art', item.arts, item.uploadArt, item.lockArt, opts.art_provider),
        'logo': ImageKind('logo', 'clearLogo', item.logos, item.uploadLogo, item.lockLogo, None),
    }
    return kinds[name]


def select_image(item, name, tmdb_path, opts):
    print(f"  Checking {name}...")
    kind = image_kind(item, name, opts)

    if item.isLocked(kind.field) and not opts.include_locked:  # PlexAPI 4.5.10
        print(f"  - Locked {name} for {full_title(item)}. Skipping.")
        return

    if tmdb_path:
        apply_tmdb_image(item, kind, tmdb_path)
        return

    if kind.fallback_provider is None:
        print(f"  - WARNING: No TMDB {name} found for {full_title(item)}. Skipping.")
        return

    images = kind.choices()
    if not images:
        print(f"  - WARNING: No available {name} for {full_title(item)}.")
        return

    select_provider_image(item, kind, images)


def find_tmdb_image(images, tmdb_path):
    '''Finds a Plex image choice matching a TMDB file path. The TMDB filename
    can appear URL-encoded in the thumb, ratingKey or key depending on the agent,
    so the comparison is done on the URL-decoded fields without the extension.'''
    stem = tmdb_path.rsplit('/', 1)[-1].rsplit('.', 1)[0]
    for image in images:
        fields = f"{image.thumb or ''} {image.ratingKey or ''} {image.key or ''}"
        if stem in unquote(fields):
            return image
    return None


def apply_tmdb_image(item, kind, tmdb_path):
    '''Selects the TMDB image among the Plex choices, uploading it when Plex
    exposes no matching source URL.'''
    match = find_tmdb_image(kind.choices(), tmdb_path)
    if match:
        match.select()  # selecting an image automatically locks the field
        print(f"  - Selected and locked TMDB {kind.name} for {full_title(item)}.")
    else:
        kind.upload(url=f"{TMDB_IMAGE_URL}{tmdb_path}")
        kind.lock()
        print(f"  - Uploaded and locked TMDB {kind.name} for {full_title(item)}.")


def select_provider_image(item, kind, images):
    '''Fallback used when TMDB has no image: keeps the current one unless it
    comes from a provider we want to replace.'''
    selected = next((image for image in images if image.selected), None)
    if selected is not None and selected.provider not in REPLACE_PROVIDERS:
        kind.lock()
        print(f"  - Locked {selected.provider} {kind.name} for {full_title(item)}.")
        return

    chosen = next((image for image in images if image.provider == kind.fallback_provider), images[0])
    chosen.select()  # selecting an image automatically locks the field
    print(f"  - Selected and locked {chosen.provider} {kind.name} for {full_title(item)}.")


def tautulli_api(cmd, **params):
    '''Calls the Tautulli API, returning an error message or None on success.'''
    if not TAUTULLI_URL or not TAUTULLI_APIKEY:
        return 'TAUTULLI_URL or TAUTULLI_APIKEY not available'

    try:
        # The API key goes in a header so it never lands in a URL or an access log
        response = requests.get(
            f"{TAUTULLI_URL}/api/v2",
            headers={'X-Api-Key': TAUTULLI_APIKEY},
            params={'cmd': cmd, **params},
            timeout=30
        )
        response.raise_for_status()
        # Tautulli reports command failures in the payload with a 200 status
        result = response.json().get('response', {})
    except (requests.RequestException, ValueError) as e:
        return str(e)

    if result.get('result') != 'success':
        return result.get('message') or 'unknown error'
    return None


def send_recently_added_notification(item, notifier_id):
    '''Triggers a Tautulli recently added notification through the given notifier,
    after the metadata has been updated.'''
    print("  Sending Tautulli notification...")

    error = tautulli_api('notify_recently_added', rating_key=item.ratingKey, notifier_id=notifier_id)
    if error:
        print(f"  - WARNING: Tautulli notification failed for {full_title(item)}: {error}")
        return

    print(f"  - Triggered recently added notification (notifier_id {notifier_id}) for {full_title(item)}.")


def send_error_notification(item, notifier_id, errors):
    '''Reports the metadata failures through the given Tautulli notifier.'''
    print("  Sending Tautulli error notification...")

    failures = '\n'.join(f"- {error}" for error in errors)
    error = tautulli_api(
        'notify',
        notifier_id=notifier_id,
        subject='Tautulli metadata script',
        body=f"Failed to apply custom metadata for {full_title(item)} "
             f"(rating_key {item.ratingKey}):\n{failures}",
    )
    if error:
        print(f"  - WARNING: Tautulli error notification failed for {full_title(item)}: {error}")
        return

    print(f"  - Triggered error notification (notifier_id {notifier_id}) for {full_title(item)}.")


def update_metadata_language(item, original_language):
    '''Returns True if the metadata language was changed and a refresh was triggered.'''
    print("  Checking metadata language...")

    if original_language is None:
        print(f"  - WARNING: Unknown original language for {full_title(item)}. Skipping.")
        return False

    if original_language == DEFAULT_ORIGINAL_LANGUAGE:
        print(f"  - Original language is '{original_language}' for {full_title(item)}. "
              "Keeping default metadata language.")
        return False

    current = next((s.value for s in item.preferences() if s.id == 'languageOverride'), None)
    if current == METADATA_LANGUAGE_OVERRIDE:
        print(f"  - Metadata language is already '{METADATA_LANGUAGE_OVERRIDE}' for {full_title(item)}.")
        return False

    item.editAdvanced(languageOverride=METADATA_LANGUAGE_OVERRIDE)
    item.refresh()
    print(f"  - Original language is '{original_language}' for {full_title(item)}. "
          f"Set metadata language to '{METADATA_LANGUAGE_OVERRIDE}' and refreshed metadata.")
    return True


def wait_for_metadata_refresh(item, timeout=10):
    '''Best effort wait for the asynchronous refresh. A title change is the signal that
    the new language landed, but it stays identical for plenty of shows. The timeout is
    kept well under the Tautulli script timeout, which would kill the notification.'''
    before = (item.title, item.updatedAt)
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(2)
        # Only reload for fields
        item.reload(**{key: 0 for key in item._INCLUDES})
        if (item.title, item.updatedAt) != before:
            return


def strip_french_article(title):
    lower = title.lower()
    for article in FRENCH_SORT_ARTICLES:
        if lower.startswith(article):
            return title[len(article):].lstrip()
    return None


def update_sort_title(item, opts, original_language):
    print("  Checking sort title...")

    if original_language is None or original_language == DEFAULT_ORIGINAL_LANGUAGE:
        print(f"  - Default metadata language for {full_title(item)}. Keeping default sort title.")
        return

    if item.isLocked('titleSort') and not opts.include_locked:
        print(f"  - Locked sort title for {full_title(item)}. Skipping.")
        return

    sort_title = strip_french_article(item.title)
    if sort_title is None:
        print(f"  - No leading French article in '{item.title}'. Keeping default sort title.")
        return

    if item.titleSort == sort_title:
        print(f"  - Sort title is already '{sort_title}' for {full_title(item)}.")
        return

    item.editSortTitle(sort_title, locked=True)
    print(f"  - Set and locked sort title '{sort_title}' for {full_title(item)}.")


@contextmanager
def step(errors, description):
    '''Isolates one metadata step: a failure is collected and reported at the end
    instead of skipping the remaining steps.'''
    try:
        yield
    except Exception as e:
        print(f"  - ERROR: Failed to apply the {description}: {e}")
        traceback.print_exc()
        errors.append(f"{description}: {e}")


def apply_metadata(item, opts):
    '''Applies every requested step, returning the descriptions of those that failed.'''
    errors = []
    if not (opts.poster or opts.art or opts.logo or opts.language or opts.sort_title):
        return errors

    targets = None
    with step(errors, 'resolution of the metadata targets'):
        targets = resolve_targets(item)
    if targets is None:
        return errors

    matched_title = full_title(targets.matched_item)

    tmdb = NO_TMDB_INFO
    with step(errors, f"TMDB lookup of {matched_title}"):
        tmdb = get_tmdb_info(targets.matched_item)

    for artwork_item in targets.artwork_items:
        if artwork_item is targets.matched_item:
            poster_path, art_path = tmdb.poster_path, tmdb.backdrop_path
        else:
            # TMDB has no per-season backdrop, and Plex seasons inherit the show art
            poster_path, art_path = tmdb.season_posters.get(artwork_item.seasonNumber), None
        if opts.poster:
            with step(errors, f"poster of {full_title(artwork_item)}"):
                select_image(artwork_item, 'poster', poster_path, opts)
        if opts.art:
            with step(errors, f"art of {full_title(artwork_item)}"):
                select_image(artwork_item, 'art', art_path, opts)

    if opts.logo:
        with step(errors, f"logo of {matched_title}"):
            select_image(targets.matched_item, 'logo', tmdb.logo_path, opts)

    # After the artwork so the metadata refresh cannot revert the locked images
    if opts.language:
        with step(errors, f"metadata language of {matched_title}"):
            if update_metadata_language(targets.matched_item, tmdb.original_language) \
                    and (opts.sort_title or opts.notify):
                # The refresh is asynchronous, later steps must see the new metadata
                wait_for_metadata_refresh(targets.matched_item)

    if opts.sort_title:
        with step(errors, f"sort title of {matched_title}"):
            update_sort_title(targets.matched_item, opts, tmdb.original_language)

    return errors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--rating_key', type=int, required=True)
    parser.add_argument('--include_locked', action='store_true')
    parser.add_argument('--poster', action='store_true')
    parser.add_argument('--poster_provider', default=PREFERRED_POSTER_PROVIDER)
    parser.add_argument('--art', action='store_true')
    parser.add_argument('--art_provider', default=PREFERRED_ART_PROVIDER)
    parser.add_argument('--logo', action='store_true')
    parser.add_argument('--language', action='store_true')
    parser.add_argument('--sort_title', action='store_true')
    parser.add_argument('--notify', type=int, metavar='NOTIFIER_ID')
    parser.add_argument('--error_notify', type=int, metavar='NOTIFIER_ID')
    opts = parser.parse_args()

    item = PlexServer(PLEX_URL, PLEX_TOKEN).fetchItem(opts.rating_key)
    # Seasons usually carry no year
    year = f" ({item.year})" if item.year else ''
    print(f"{full_title(item)}{year}")

    errors = apply_metadata(item, opts)

    # Last so the notification carries the updated metadata
    if opts.notify:
        send_recently_added_notification(item, opts.notify)
    if errors and opts.error_notify:
        send_error_notification(item, opts.error_notify, errors)

    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
