# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

package Bugzilla::Extension::BugmailFilter::Constants;

use 5.10.1;
use strict;
use warnings;

use base qw(Exporter);

our @EXPORT = qw(
  FAKE_FIELD_NAMES
  IGNORE_FIELDS
  FIELD_DESCRIPTION_OVERRIDE
  FILTER_RELATIONSHIPS
);

use Bugzilla::Constants;

# these are field names which are inserted into X-Bugzilla-Changed-Field-Names
# header but are not real fields

use constant FAKE_FIELD_NAMES => [
  {name => 'comment.created',    description => 'Comment created',},
  {name => 'attachment.created', description => 'Attachment created',},
];

# these fields don't make any sense to filter on

use constant IGNORE_FIELDS => qw(
  assignee_last_login
  attach_data.thedata
  attachments.count
  attachments.submitter
  blocked.count
  cc_count
  cf_last_resolved
  commenter
  comment_tag
  creation_ts
  days_elapsed
  delta_ts
  dependson.count
  dupe_count
  everconfirmed
  keywords.count
  last_visit_ts
  longdesc
  longdescs.count
  owner_idle_time
  regressed_by.count
  regresses.count
  reporter
  reporter_accessible
  setters.login_name
  tag
  votes
);

# override the description of some fields

use constant FIELD_DESCRIPTION_OVERRIDE => {bug_id => 'Bug Created',};

# relationship / int mappings
# _should_drop() also needs updating when this is changed

sub FILTER_RELATIONSHIPS() {
  state $relations;
  return \@$relations if $relations;
  my $index = 1;
  push @$relations, { name => 'Assignee', value => $index++ };
  push @$relations, { name => 'Not Assignee', value => $index++ };
  push @$relations, { name => 'Reporter', value => $index++ };
  push @$relations, { name => 'Not Reporter', value => $index++ };
  push @$relations, { name => 'QA Contact', value => $index++ };
  push @$relations, { name => 'Not QA Contact', value => $index++ };
  push @$relations, { name => "CC'ed", value => $index++ };
  push @$relations, { name => "Not CC'ed", value => $index++ };
  push @$relations, { name => 'Watching', value => $index++ };
  push @$relations, { name => 'Not Watching', value => $index++ };
  if (Bugzilla->have_extension('Review')) {
    push @$relations, { name => 'Mentoring', value => $index++ };
    push @$relations, { name => 'Not Mentoring', value => $index++ };
  }
	return \@$relations;
}

1;
