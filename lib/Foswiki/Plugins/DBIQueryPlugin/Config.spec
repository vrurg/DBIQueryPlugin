# ---+ Extensions
# ---++ DBIQueryPlugin
#
# **BOOLEAN**
# Debugging flag for the plugin.
$Foswiki::cfg::{Plugins}{DBIQueryPlugin} = 0;

# **NUMBER**
# Defines how many recursions could be performed on a query before it's considered endless or too deep.
$Foswiki::cfg::{Plugins}{DBIQueryPlugin}{maxRecursionLevel} = 100;

# **STRING EXPERT**
# DON'T CHANGLE unless 101% sure that this is exactly what you need!
# Kind of a braces used to mark areas of HTML code being protected from unneeded processing.
$Foswiki::cfg::{Plugins}{DBIQueryPlugin}{protectStart} = '!&lt;ProtectStart&gt;';
$Foswiki::cfg::{Plugins}{DBIQueryPlugin}{protectEnd} = '!&lt;ProtectEnd&gt';
1;
# vim: ft=perl et ts=4
