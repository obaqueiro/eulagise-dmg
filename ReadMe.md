Note: This is a fork of [this](https://gitorious.org/eulagise/eulagise) Gitorious project with
minimal changes. The original blog post from Pete Goodliffe explaining this code is [here](http://goodliffe.blogspot.com/2010/08/eulogise-adding-eula-to-dmg.html).
# Eulagise Read Me

My code projects usually include a release script, a shell script that does
something like this:

    * cleans the build tree,
    * rebuilds the project,
    * runs the unit tests (stopping if they fail), and
    * packages the project.

It's that last step I'm concerned with here. On Mac OS packaging usually
involves building a DMG disk image. Automatically creating a DMG isn't entirely
straightforward in a shell script. In fact, it's not straightforward at all. It
took me a while to master the process; I bastardised and tweaked part of the
Audium build process to perform this feat of engineering.

A recent requirement was to add a EULA to the DMG. If you're a Mac user then
you've probably seen them once or twice.

The EULA appears when you double-click the DMG file, if you agree to the EULA
then the disk image opens. If you don't agree, then, well you can work out the
rest.

Something so simple, and so standard, must be easy to add. Right?

I hate to spoil a good story, but it's a bit tricky. Don't worry, the story has
a happy ending.

It's not an easy task because:

    * The EULA has to be in a very particular format.
    * The EULA has to be added to the resource fork of the DMG.
    * You can only add resources (i.e. the EULA) to an unflattened DMG object,
      use the Rez utility to add resources, and re-flatten the DMG.
    * There are no clear and easy docs on the subject. (That I could find.)

Of course, being a script we want this to be automated, rather than a
clicky-draggy process. There are programs that'll do clicky-draggy. We have to
rule those out.

Ideally we want a script that takes a text file as input and the DMG to attach
it to. Magic invisible elves inside the script do the rest.

I spent some time writing my own script, hitting a number of obstacles each
time around, and then research pointed me towards the Seamonkey build system.
Seamonkey has a script here that can do it. Hurrah! The script also creates the
DMG in the first place, setting icons, volume name, etc. Sounds great, except
that it does all the other stuff rather badly. Or at least, less well than the
script I already created.

So I removed all the other cruft, and paired Seamonkey's script down into
eulagise. Elaugise is a simple (ish) script to add a EULA to a pre-existing
DMG. You use it like this:

    ./eulagise.pl --license MyEula.txt --target MyDiskImage.dmg

Simples.

